import AppKit
import LedgeShellCore
import QuartzCore

/// Maps the protocol component vocabulary (spec §5) onto AppKit views and keeps
/// each app's live view tree in sync with validated commits (§3.1). Because the
/// engine only ever hands over mutation lists that already passed shadow-tree
/// validation, this applies them inside one `CATransaction` without re-checking.
@MainActor
final class ProtocolRenderer: ProtocolEngineDelegate {
    /// Per-app live view state, mirroring the engine's shadow tree with real
    /// views.
    final class AppTree {
        var views: [Int: NSView] = [:]
        var kinds: [Int: ComponentKind] = [:]
        var props: [Int: [String: JSONValue]] = [:]
        var canvases: [Int: ProtocolCanvasView] = [:]
        var rootID: Int?
        /// The app's panel-wing node, if it mounted one (spec §5 `wing`). Its
        /// view lives in the shell's zone, not in this tree's content stack.
        var wingID: Int?
        /// The app's mini-view node, if it mounted one (spec §5 `mini`). Like
        /// the wing, its view lives in a shell surface rather than this tree's
        /// content stack — which is what lets a peek be instant.
        var miniID: Int?
        /// The app's `summary` node, if it mounted one (spec §5 `summary`).
        /// Same story as `mini`: a root-level zone whose view lives in a shell
        /// surface. Its presence is also the answer to "is this session heavy",
        /// which is what the hover machinery asks at Th.
        var summaryID: Int?
        /// Set while an error card replaces the app tree.
        var errorCard: NSView?
    }

    /// Wire outbound events (§4.1). Set by the host session.
    var onEvent: ((_ app: String, _ id: Int, _ name: String, _ data: JSONValue) -> Void)?
    /// The app's content changed; the panel may need to re-measure/re-present.
    var onContentChanged: ((_ app: String) -> Void)?
    var onCatalog: ((CatalogPayload) -> Void)?
    var onBuilder: ((BuilderPayload) -> Void)?
    var onChrome: ((
        _ app: String,
        _ request: String,
        _ wing: WingSpec?,
        _ ms: Double?,
        _ priority: NotificationClass?
    ) -> Void)?
    var onLifecycle: ((_ app: String, _ state: String) -> Void)?
    /// The error card's one action: restart the whole host (flow.md, Errors).
    /// Set by `HostSession`, which gets it from the app delegate — the only
    /// object that holds the `HostProcess`.
    var onReloadHost: (() -> Void)?

    private var trees: [String: AppTree] = [:]

    /// A second destination for one app's draw frames: the notch wing's canvas
    /// strip (spec §3.3 extension). The same `(app, id)` frames that feed the
    /// in-panel canvas are blitted here too, so a wing canvas and a panel canvas
    /// can be the same node — the app draws once.
    private var wingTarget: (app: String, id: Int, view: ProtocolCanvasView)?

    /// Default content width available to a host tree (panel body inside the
    /// fillets); an app may declare another via `meta.panel.width` (spec §5).
    static let contentWidth: CGFloat = PanelLimits.defaultWidth

    /// How tall a scrolling `stack` (spec §5 `scroll`) may grow before it starts
    /// scrolling: that app's panel content ceiling. Supplied by the host session,
    /// which owns `PanelLimits`; the fallback is the snapshot limit so headless
    /// rendering and `swift test` agree with a live screen's proportions.
    var scrollCap: ((_ app: String) -> CGFloat)?

    private func scrollCapHeight(for app: String) -> CGFloat {
        // The only chrome a panel spends now is the cutout exclusion row: the
        // bottom app strip is gone (flow.md — the wings are Ledge's controls).
        scrollCap?(app) ?? (PanelLimits.fallback.maxHeight - NotchMetrics.fallback.closedHeight)
    }

    // MARK: - Query (for the host session / tests)

    func rootView(for app: String) -> NSView? {
        let tree = trees[app]
        if let card = tree?.errorCard { return card }
        guard let id = tree?.rootID else { return nil }
        return tree?.views[id]
    }

    func view(app: String, id: Int) -> NSView? { trees[app]?.views[id] }
    func kind(app: String, id: Int) -> ComponentKind? { trees[app]?.kinds[id] }
    func canvas(app: String, id: Int) -> ProtocolCanvasView? { trees[app]?.canvases[id] }

    /// The app's panel-wing content, or nil when it mounted none — in which case
    /// the shell shows its own default (the catalog name). This is the whole
    /// public surface of the `wing` kind: the panel controller asks for it on
    /// every refresh, so a wing appearing, changing or being removed needs no
    /// separate notification.
    func wingView(for app: String) -> NSView? {
        guard let tree = trees[app], let id = tree.wingID else { return nil }
        return tree.views[id]
    }

    /// The app's mini-view content, or nil when it mounted none — in which case
    /// a `peek` has nothing to show and the shell declines it (spec §3.3:
    /// denials are silent). Asked for on demand, exactly like `wingView`, so an
    /// app whose mini changes between peeks needs no notification.
    func miniView(for app: String) -> NSView? {
        guard let tree = trees[app], let id = tree.miniID else { return nil }
        return tree.views[id]
    }

    /// The app's `summary` content, or nil when it declared none — in which case
    /// the session is *light* and a hover that reaches Th opens the visit
    /// directly (flow.md, Summary; principle 8). Asked on demand like the other
    /// two zones, so declaring or dropping a summary needs no notification.
    func summaryView(for app: String) -> NSView? {
        guard let tree = trees[app], let id = tree.summaryID else { return nil }
        return tree.views[id]
    }

    /// Whether this session is *heavy*: does it owe the hover a summary?
    func declaresSummary(for app: String) -> Bool {
        trees[app]?.summaryID != nil
    }

    /// The first canvas in `app`'s tree that asked to be focusable (spec §5).
    /// The panel controller focuses it when the app is presented — without that,
    /// `onKey` (§4.1) only ever fires after the user happens to click the canvas,
    /// which is not a game.
    func focusableCanvas(for app: String) -> ProtocolCanvasView? {
        guard let tree = trees[app] else { return nil }
        return tree.canvases
            .sorted { $0.key < $1.key }
            .first { $0.value.focusable }?
            .value
    }

    /// Point the notch wing's canvas strip at one app's canvas node, or clear it
    /// with `nil` (spec §3.3 extension).
    func setWingTarget(app: String?, id: Int?, view: ProtocolCanvasView) {
        if let app, let id {
            wingTarget = (app, id, view)
        } else {
            wingTarget = nil
        }
    }

    /// Fitting height of the app's root tree, used for panel sizing (§5).
    ///
    /// Measured more than once on purpose. A wrapping `text` (maxLines > 1, §5)
    /// cannot know its own height until it knows its column, and it only learns
    /// the column from a layout pass — so the first answer is one line tall and
    /// the second is the truth. The loop settles as soon as two passes agree,
    /// which for every tree without wrapped text is immediately.
    func rootFittingHeight(for app: String) -> CGFloat {
        guard let root = rootView(for: app) else { return 0 }
        root.layoutSubtreeIfNeeded()
        var height = ceil(root.fittingSize.height)
        for _ in 0..<3 {
            root.layoutSubtreeIfNeeded()
            let settled = ceil(root.fittingSize.height)
            if settled == height { break }
            height = settled
        }
        return height
    }

    // MARK: - ProtocolEngineDelegate

    func applyCommit(app: String, mutations: [Mutation]) {
        let tree = trees[app] ?? { let new = AppTree(); trees[app] = new; return new }()
        tree.errorCard = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)          // no implicit layer animations (§ traps)
        for mutation in mutations {
            apply(mutation, app: app, tree: tree)
        }
        CATransaction.commit()

        // Proves an end-to-end commit landed and validated (used by the e2e smoke).
        NSLog("[ledge] applied commit app=%@ mutations=%d", app, mutations.count)
        onContentChanged?(app)
    }

    func discardApp(_ app: String) {
        trees[app] = nil
        onContentChanged?(app)
    }

    func discardAllApps() {
        trees.removeAll()
    }

    func showErrorCard(app: String, message: String, stack: String?) {
        let tree = trees[app] ?? { let new = AppTree(); trees[app] = new; return new }()
        // `message` and `stack` are deliberately dropped on the floor here: the
        // card is generic by decision (flow.md, Errors), and the diagnosis is
        // already on its way to ~/.ledge/host.log. They stay in the signature
        // because they are still on the wire (spec §3.2).
        NSLog("[ledge] app crashed app=%@ message=%@", app, message)
        tree.errorCard = ErrorCardView(onReload: { [weak self] in self?.onReloadHost?() })
        onContentChanged?(app)
    }

    func appLifecycle(app: String, state: String) {
        onLifecycle?(app, state)
    }

    func chromeRequest(
        app: String,
        request: String,
        wing: WingSpec?,
        ms: Double?,
        priority: NotificationClass?
    ) {
        onChrome?(app, request, wing, ms, priority)
    }

    func drawCanvas(app: String, id: Int, ops: [JSONValue]) {
        // Node ids restart at 1 in every worker (spec §3.1), so two running apps
        // routinely both own an id 12 — the lookup has to be scoped by app or one
        // app's frames land on another's canvas.
        trees[app]?.canvases[id]?.apply(ops: ops)
        // The same frame also feeds the notch wing when this node is the one the
        // app named there, so a wing canvas costs the app no extra draw calls.
        if let target = wingTarget, target.app == app, target.id == id {
            target.view.apply(ops: ops)
        }
    }

    func catalogUpdated(_ catalog: CatalogPayload) {
        onCatalog?(catalog)
    }

    func builderEvent(_ payload: BuilderPayload) {
        onBuilder?(payload)
    }

    // MARK: - Mutation application

    private func apply(_ mutation: Mutation, app: String, tree: AppTree) {
        switch mutation.op {
        case .create:
            guard let id = mutation.id, let rawKind = mutation.kind,
                  let kind = ComponentKind(rawValue: rawKind) else { return }
            let props = mutation.props ?? [:]
            let view = makeView(kind: kind, id: id, app: app, props: props, tree: tree)
            view.translatesAutoresizingMaskIntoConstraints = false
            tree.views[id] = view
            tree.kinds[id] = kind
            tree.props[id] = props
            configure(view, kind: kind, props: props)

        case .insert:
            guard let parent = mutation.parent, let id = mutation.id,
                  let parentView = tree.views[parent], let childView = tree.views[id] else { return }
            // A `wing` is the app's content for shell chrome: the shadow tree has
            // already established it is a direct child of the root, and its view
            // belongs in the zone beside the camera, not in the root's stack.
            // Adding it here would put the app's status line back exactly where
            // this whole feature exists to remove it from.
            // Zone kinds (`wing`, `mini`) are the app's content for shell
            // chrome: the shadow tree has already established each is a direct
            // child of the root, and their views belong in the surfaces the
            // shell owns, not in the root's stack. Inserting them here would put
            // the app's status line back exactly where this whole feature exists
            // to remove it from — and would render the mini view inline, in the
            // panel, which is not a place it means anything.
            switch tree.kinds[id] {
            case .wing:
                tree.wingID = id
                return
            case .mini:
                tree.miniID = id
                return
            case .summary:
                tree.summaryID = id
                return
            default:
                break
            }
            insert(childView, into: parentView, before: mutation.before, tree: tree)

        case .update:
            guard let id = mutation.id, let view = tree.views[id],
                  let kind = tree.kinds[id] else { return }
            var merged = tree.props[id] ?? [:]
            for (key, value) in mutation.props ?? [:] {
                if case .null = value { merged[key] = nil } else { merged[key] = value }
            }
            tree.props[id] = merged
            configure(view, kind: kind, props: merged)

        case .remove:
            guard let id = mutation.id else { return }
            removeSubtree(id, tree: tree)

        case .setRoot:
            tree.rootID = mutation.id
        }
    }

    private func insert(_ child: NSView, into parent: NSView, before: Int?, tree: AppTree) {
        // A scrolling stack's children belong to the stack inside its clip view,
        // not to the wrapper the parent holds (see `LedgeContentHosting`).
        let parent = (parent as? LedgeContentHosting)?.contentView ?? parent
        if let stack = parent as? NSStackView {
            let index: Int
            if let before, let beforeView = tree.views[before],
               let position = stack.arrangedSubviews.firstIndex(of: beforeView) {
                index = position
            } else {
                index = stack.arrangedSubviews.count
            }
            stack.insertArrangedSubview(child, at: index)
            tieSpacers(in: stack)
            (stack as? LedgeStackView)?.syncFillWidths()
            // The wrapper's capped height is derived from the stack's content, so
            // it has to re-measure when the content arrives.
            (stack as? LedgeStackView)?.scrollHost?.contentChanged()
        } else if let button = parent as? LedgeButton {
            // `button` takes a label *or a child* (§5). The child is the button —
            // it decides the size, the button decides the press.
            button.host(child)
        } else {
            // No other kind is attachable, but a future one that is gets a
            // centred child rather than a silently dropped one.
            parent.addSubview(child)
            NSLayoutConstraint.activate([
                child.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                child.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
            ])
        }
    }

    /// Every `spacer` in a stack takes an equal share of the leftover space —
    /// the `flex: 1` every layout system means by "spacer". Without this, two
    /// spacers around a group are an ambiguous split and Auto Layout silently
    /// gives all of it to one, so "centered" comes out flush right.
    private var spacerGroups: [ObjectIdentifier: [NSLayoutConstraint]] = [:]

    private func tieSpacers(in stack: NSStackView) {
        let key = ObjectIdentifier(stack)
        NSLayoutConstraint.deactivate(spacerGroups[key] ?? [])
        spacerGroups[key] = nil

        let spacers = stack.arrangedSubviews.compactMap { $0 as? LedgeSpacerView }
        guard let first = spacers.first, spacers.count > 1 else { return }
        let horizontal = stack.orientation == .horizontal
        let constraints = spacers.dropFirst().map { spacer in
            horizontal
                ? spacer.widthAnchor.constraint(equalTo: first.widthAnchor)
                : spacer.heightAnchor.constraint(equalTo: first.heightAnchor)
        }
        NSLayoutConstraint.activate(constraints)
        spacerGroups[key] = constraints
    }

    private func removeSubtree(_ id: Int, tree: AppTree) {
        var stack = [id]
        while let current = stack.popLast() {
            if let view = tree.views[current] {
                let container = (view as? LedgeContentHosting)?.contentView ?? view
                // A stack's children are its *arranged* subviews; anything else
                // attachable (a `button` hosting a row) keeps them as plain
                // subviews. Views the tree doesn't know — a button's own label —
                // simply don't resolve to an id and are skipped.
                let children = (container as? NSStackView)?.arrangedSubviews ?? container.subviews
                for sub in children {
                    if let subID = tree.views.first(where: { $0.value === sub })?.key {
                        stack.append(subID)
                    }
                }
                // Captured before the removal: a stack that has just lost a
                // child has to re-derive its fill/hug decision, because both
                // depend on which children it still has (a row that loses its
                // `spacer` stops filling and starts hugging).
                let host = view.superview as? LedgeStackView
                view.removeFromSuperview()
                if let host {
                    tieSpacers(in: host)
                    host.syncFillWidths()
                }
            }
            tree.views[current] = nil
            tree.kinds[current] = nil
            tree.props[current] = nil
            tree.canvases[current] = nil
            // Removing a zone node releases the surface it filled: an app that
            // stops having something to say up there gets the shell's default
            // back, not an empty gap. All three zones, because an app that drops
            // its `summary` has stopped being a heavy session and must start
            // opening straight to the visit on hover.
            if tree.wingID == current { tree.wingID = nil }
            if tree.miniID == current { tree.miniID = nil }
            if tree.summaryID == current { tree.summaryID = nil }
            if tree.rootID == current {
                tree.rootID = nil
                // The zones are not in the root's *view* hierarchy (that is the
                // whole point), so the walk above cannot reach them. But each is
                // a direct child of the root in the tree, so a root that goes
                // takes them with it — otherwise a replaced root would leave a
                // stale zone view for the next commit to render.
                tree.wingID = nil
                tree.miniID = nil
                tree.summaryID = nil
            }
        }
    }

    // MARK: - View construction (spec §5)

    private func makeView(
        kind: ComponentKind,
        id: Int,
        app: String,
        props: [String: JSONValue],
        tree: AppTree
    ) -> NSView {
        switch kind {
        case .stack:
            let axis: LedgeAxis = props["axis"]?.asString == "h" ? .horizontal : .vertical
            let stack = LedgeStackView(
                axis: axis,
                gap: cgFloat(props["gap"], default: LedgeMetrics.gap),
                pad: cgFloat(props["pad"], default: 0)
            )
            // `scroll` (spec §5): only vertical. A horizontal stack that asked is
            // ignored rather than guessed at — nothing in the vocabulary is wider
            // than its column, so a sideways scroller would only ever hide a
            // layout bug.
            guard axis == .vertical, props["scroll"]?.asBool == true else { return stack }
            return LedgeScrollStackView(stack: stack, maxHeight: scrollCapHeight(for: app))

        case .text:
            return LedgeText(props["content"]?.asString ?? "")

        case .button:
            // `icon` (spec §5 proposal): an "sf:<symbol>" leading the label.
            let icon = props["icon"]?.asString.map { raw in
                raw.hasPrefix("sf:") ? String(raw.dropFirst(3)) : raw
            }
            let button = LedgeButton(
                props["label"]?.asString ?? "",
                symbol: icon,
                variant: Self.variant(props["variant"]?.asString),
                size: LedgeMetrics.Size(token: props["size"]?.asString),
                disabled: props["disabled"]?.asBool ?? false,
                handler: { [weak self] in self?.onEvent?(app, id, "click", .object([:])) }
            )
            return button

        // MARK: New kinds (D6). Every one of them is also reachable by `update`.

        case .toggle:
            let toggle = LedgeToggle(
                on: props["on"]?.asBool ?? false,
                disabled: props["disabled"]?.asBool ?? false
            ) { [weak self] on in
                self?.onEvent?(app, id, "change", .object(["on": .bool(on)]))
            }
            constrainSize(toggle, width: LedgeMetrics.toggleWidth, height: LedgeMetrics.toggleHeight)
            return toggle

        case .segment:
            let segment = LedgeSegment(
                options: Self.segmentOptions(props["options"]),
                value: props["value"]?.asString ?? ""
            ) { [weak self] value in
                self?.onEvent?(app, id, "change", .object(["value": .string(value)]))
            }
            segment.heightAnchor.constraint(equalToConstant: LedgeMetrics.segmentHeight).isActive = true
            return segment

        case .stepper:
            let stepper = LedgeStepper(
                value: props["value"]?.asDouble ?? 0,
                min: props["min"]?.asDouble ?? -Double.greatestFiniteMagnitude,
                max: props["max"]?.asDouble ?? Double.greatestFiniteMagnitude,
                step: props["step"]?.asDouble ?? 1,
                format: props["format"]?.asString
            ) { [weak self] value in
                self?.onEvent?(app, id, "change", .object(["value": .double(value)]))
            }
            stepper.heightAnchor.constraint(equalToConstant: LedgeMetrics.stepperHeight).isActive = true
            return stepper

        case .progress:
            let progress = LedgeProgress(
                value: props["value"]?.asDouble ?? 0,
                color: Self.meterColor(props["color"]?.asString)
            )
            progress.heightAnchor.constraint(equalToConstant: LedgeMetrics.progressHeight).isActive = true
            progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return progress

        case .wing:
            // No size constraints: the zone frames it (see `PanelWingBarView`),
            // and a wing that could ask for a width could ask for one wider than
            // the gap between the panel edge and the camera.
            return LedgeWingView()

        case .mini:
            // The surface sizes itself to this view's fitting size and clamps
            // (see `MiniContentView`), so the app never names a width — a mini
            // that could would eventually ask to be the panel, and the panel
            // already exists. `LedgeMiniView`, not `LedgeWingView`: only the
            // former reports a real fitting size (see its doc comment).
            return LedgeMiniView()

        case .summary:
            // The same shape as `mini`, and deliberately the same view: the two
            // swells share a geometry, so a summary that measured itself
            // differently from a notification would make the notch grow to two
            // different heights for the same one-row content.
            return LedgeMiniView()

        case .spinner:
            let spinner = LedgeSpinner()
            constrainSize(spinner, width: LedgeMetrics.spinnerSize, height: LedgeMetrics.spinnerSize)
            return spinner

        case .pill:
            let pill = LedgePill(
                text: props["label"]?.asString ?? "",
                tone: LedgePill.Tone(token: props["tone"]?.asString)
            )
            pill.heightAnchor.constraint(equalToConstant: LedgeMetrics.pillHeight).isActive = true
            return pill

        case .image:
            // Two kinds of `src` (spec §5): an SF Symbol behind `sf:`, or an
            // absolute path to a file the app owns — apps build those from
            // `import.meta.dir`, so a path always arrives absolute.
            let src = props["src"]?.asString ?? ""
            let radius = cgFloat(props["radius"], default: 0)
            let image: NSView = src.hasPrefix("sf:")
                ? LedgeSymbolView(symbol: String(src.dropFirst(3)), radius: radius)
                : LedgeFileImageView(path: src, radius: radius)
            // `stroke` (spec §5): the same hairline vocabulary a stack names, on
            // the image view itself. An artwork well whose bitmap letterboxes —
            // or fails to load at all — keeps the frame the layout drew for it,
            // and it costs no wrapper stack (which would double-frame it).
            image.applyHairlineStroke(Self.strokeToken(props["stroke"]?.asString))
            constrainSize(
                image,
                width: cgFloat(props["w"], default: 24),
                height: cgFloat(props["h"], default: 24)
            )
            return image

        case .divider:
            // No props and no size to negotiate: the column gives it a width, the
            // theme gives it a colour, and that is the whole component.
            return LedgeDividerView()

        case .spacer:
            let spacer = LedgeSpacerView()
            if let min = props["min"]?.asDouble {
                spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(min)).isActive = true
            }
            return spacer

        case .chart:
            let chart = LedgeChartView(
                points: (props["points"]?.asArray ?? []).compactMap { $0.asDouble.map { CGFloat($0) } },
                color: Self.semanticColor(props["color"]?.asString),
                showsFill: props["fill"]?.asBool ?? false
            )
            chart.heightAnchor.constraint(equalToConstant: LedgeMetrics.chartHeight).isActive = true
            chart.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return chart

        case .slider:
            // `min`/`max`/`step` (spec §5) are honored from create, so an app's
            // first commit already carries its own scale rather than 0…1.
            let slider = LedgeSlider(
                value: props["value"]?.asDouble ?? 0,
                min: props["min"]?.asDouble ?? 0,
                max: props["max"]?.asDouble ?? 1,
                step: props["step"]?.asDouble
            ) { [weak self] value in
                self?.onEvent?(app, id, "change", .object(["value": .double(value)]))
            }
            slider.heightAnchor.constraint(equalToConstant: LedgeMetrics.sliderHeight).isActive = true
            slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return slider

        case .input:
            let input = LedgeInput(placeholder: props["placeholder"]?.asString ?? "") { [weak self] text in
                self?.onEvent?(app, id, "change", .object(["value": .string(text)]))
            }
            input.heightAnchor.constraint(equalToConstant: LedgeMetrics.inputHeight).isActive = true
            input.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return input

        case .canvas:
            let canvas = ProtocolCanvasView()
            canvas.focusable = props["focusable"]?.asBool ?? false
            canvas.onKey = { [weak self] key, down in
                self?.onEvent?(app, id, "key", .object(["key": .string(key), "down": .bool(down)]))
            }
            canvas.onClick = { [weak self] point in
                self?.onEvent?(app, id, "click", .object([
                    "x": .double(Double(point.x)),
                    "y": .double(Double(point.y)),
                ]))
            }
            // `drag` (§4.1): press-drag-release, throttled shell-side. The
            // closure is wired here like every other handler; whether it fires
            // is `dragEnabled`, resolved from the merged props in `configure` —
            // a canvas that never declared `onDrag` must not put 30 events a
            // second on the socket for a gesture nobody subscribed to.
            canvas.onDrag = { [weak self] phase, point in
                self?.onEvent?(app, id, "drag", .object([
                    "phase": .string(phase),
                    "x": .double(Double(point.x)),
                    "y": .double(Double(point.y)),
                ]))
            }
            constrainSize(
                canvas,
                width: cgFloat(props["w"], default: 120),
                height: cgFloat(props["h"], default: 60)
            )
            tree.canvases[id] = canvas
            return canvas
        }
    }

    // MARK: - Configuration (idempotent; used on create and update)

    private func configure(_ view: NSView, kind: ComponentKind, props: [String: JSONValue]) {
        switch kind {
        case .stack:
            // A scrolling stack's props belong to the stack, not to its wrapper.
            guard let stack = ((view as? LedgeContentHosting)?.contentView ?? view) as? LedgeStackView else { return }
            if let gap = props["gap"]?.asDouble { stack.spacing = CGFloat(gap) }
            if let pad = props["pad"]?.asDouble {
                stack.edgeInsets = NSEdgeInsets(top: CGFloat(pad), left: CGFloat(pad), bottom: CGFloat(pad), right: CGFloat(pad))
            }
            if let axis = props["axis"]?.asString {
                stack.orientation = axis == "h" ? .horizontal : .vertical
                // .leading, never .width: NSStackView's .width alignment pins a
                // nested stack to the container's *outer* edges, so a padded box's
                // eyebrow row overhangs the pad into the corner (the chess STATUS
                // bug). Full-width behavior comes from syncFillWidths, whose
                // constraints respect the insets.
                stack.alignment = axis == "h" ? .centerY : .leading
            }
            applyAlign(stack, props["align"]?.asString)
            // `distribute` (spec §5): `equal` is what makes a row of chips or
            // buttons share the width evenly without any app doing arithmetic.
            // Declared rather than set: a row with nothing width-less in it is
            // laid out on `.gravityAreas` so it stops flinging its children to
            // opposite edges, and `syncFillWidths` owns that decision.
            stack.declaredDistribution =
                props["distribute"]?.asString == "equal" ? .fillEqually : .fill
            stack.syncFillWidths()          // `pad` feeds the fill width
            stack.applyContainer(
                fill: Self.fillToken(props["fill"]?.asString),
                stroke: Self.strokeToken(props["stroke"]?.asString),
                radius: props["radius"]?.asDouble.map { CGFloat($0) },
                gradient: Self.gradientToken(props["gradient"]?.asString)
            )

        case .text:
            guard let field = view as? NSTextField else { return }
            // Face and ink first, then the string: `caps` rebuilds the field as
            // an attributed value (tracking is not a font trait), and it has to
            // build it out of the face this commit asked for.
            field.font = Self.font(size: props["size"]?.asString, weight: props["weight"]?.asString, mono: props["mono"]?.asBool ?? false)
            field.textColor = Self.semanticColor(props["color"]?.asString, default: LedgeTheme.primary)
            if let text = field as? LedgeText {
                text.applyContent(props["content"]?.asString, caps: props["caps"]?.asBool ?? false)
            } else if let content = props["content"]?.asString {
                field.stringValue = content
            }
            // `maxLines`/`truncate` (spec §5, law L7): both resolved from the
            // merged prop set, so dropping `maxLines` really does go back to one
            // line rather than reading as "unchanged".
            (field as? LedgeText)?.applyLines(
                maxLines: props["maxLines"]?.asInt ?? 1,
                truncate: props["truncate"]?.asBool ?? true
            )
            // Setting `font` does not invalidate the cached intrinsic size, so a
            // node created at the default size and then configured to `xl` would
            // be laid out at the old width and truncate mid-price. Ask for a
            // re-measure explicitly.
            field.invalidateIntrinsicContentSize()

        case .chart:
            guard let chart = view as? LedgeChartView else { return }
            if let points = props["points"]?.asArray {
                chart.points = points.compactMap { $0.asDouble.map { CGFloat($0) } }
            }
            if let color = props["color"]?.asString {
                chart.color = Self.semanticColor(color)
                chart.needsDisplay = true
            }

        case .slider:
            guard let slider = view as? LedgeSlider else { return }
            // Scale first, then the value — an app that narrows `max` and moves
            // the thumb in one commit must not be clamped against the old range.
            slider.applyRange(
                min: props["min"]?.asDouble,
                max: props["max"]?.asDouble,
                step: .some(props["step"]?.asDouble)
            )
            // `rate` before `value`: the committed value is reconciled *against*
            // the self-advance, so the control has to know whether it is
            // advancing before it decides to jump or to glide.
            slider.applyRate(props["rate"]?.asDouble)
            if let value = props["value"]?.asDouble { slider.applyCommittedValue(value) }

        case .input:
            guard let input = view as? LedgeInput else { return }
            if let value = props["value"]?.asString { input.setText(value) }

        case .canvas:
            guard let canvas = view as? ProtocolCanvasView else { return }
            canvas.focusable = props["focusable"]?.asBool ?? canvas.focusable
            // Resolved, not optional: `configure` sees the merged prop set, so
            // dropping `onDrag` (null, §3.1) really does stop the phases.
            canvas.dragEnabled = props["onDrag"]?.asBool ?? false

        case .button:
            guard let button = view as? LedgeButton else { return }
            // Partial props: absent = unchanged, null = delete (spec §3.1).
            let symbol: String?? = props["icon"].map { value in
                value.asString.map { raw in
                    raw.hasPrefix("sf:") ? String(raw.dropFirst(3)) : raw
                }
            }
            // `size` and `disabled` are resolved rather than optional: `configure`
            // always receives the *merged* prop set, so a deleted `disabled`
            // (null, §3.1) has to re-enable the button rather than read as
            // "unchanged" — that is the create-only-prop bug all over again.
            button.apply(
                label: props["label"]?.asString,
                symbol: symbol,
                variant: props["variant"]?.asString.map { Self.variant($0) },
                size: LedgeMetrics.Size(token: props["size"]?.asString),
                disabled: props["disabled"]?.asBool ?? false
            )

        case .image:
            // `w`/`h` are create-time constraints, but `src` and `radius` change
            // in place: an app swapping artwork sends an `update` op on the same
            // node (§3.1), not a new one. An `sf:` symbol node stays a symbol
            // node — a src that changes *kind* is a different component.
            //
            // **Both kinds update.** This used to `guard let image = view as?
            // LedgeFileImageView`, which silently dropped every `src` update on
            // a symbol node: a bell that became a timer kept the bell until the
            // app forced a remount with a React `key`. G3.
            //
            // `stroke` is resolved rather than optional, on both kinds of image:
            // `configure` sees the merged prop set, so a deleted `stroke` (null,
            // §3.1) has to take the ring away instead of reading as "unchanged".
            view.applyHairlineStroke(Self.strokeToken(props["stroke"]?.asString))
            let radius = props["radius"]?.asDouble.map { CGFloat($0) }
            let src = props["src"]?.asString
            if let symbol = view as? LedgeSymbolView {
                // A `src` that changes *kind* (file → symbol or back) is a
                // different component, so only the `sf:` form lands here; a bare
                // path arriving at a symbol node is ignored rather than drawn as
                // a symbol called "/Users/…".
                symbol.apply(
                    symbol: src.flatMap { $0.hasPrefix("sf:") ? String($0.dropFirst(3)) : nil },
                    radius: radius
                )
            } else if let image = view as? LedgeFileImageView {
                image.apply(path: src, radius: radius)
            }

        case .spacer:
            // Built fully at create; `min` doesn't change in practice.
            break

        case .divider:
            // A rule has no state. An `update` op on one is legal and does
            // nothing, exactly like `spinner`.
            break

        // MARK: New kinds (D6). All of them update in place — no create-only props.

        case .toggle:
            guard let toggle = view as? LedgeToggle else { return }
            // Resolved, not optional: `configure` sees the merged prop set, so a
            // deleted key means "back to the default", never "unchanged".
            toggle.apply(
                on: props["on"]?.asBool ?? false,
                disabled: props["disabled"]?.asBool ?? false
            )

        case .segment:
            guard let segment = view as? LedgeSegment else { return }
            segment.apply(
                options: Self.segmentOptions(props["options"]),
                value: props["value"]?.asString ?? ""
            )

        case .stepper:
            guard let stepper = view as? LedgeStepper else { return }
            stepper.apply(
                value: props["value"]?.asDouble,
                // Absent bounds mean unbounded, exactly as at create — an alarm
                // that wraps 23:00 → 00:00 does its own arithmetic and must not
                // meet a clamp the shell invented.
                min: props["min"]?.asDouble ?? -Double.greatestFiniteMagnitude,
                max: props["max"]?.asDouble ?? Double.greatestFiniteMagnitude,
                step: props["step"]?.asDouble ?? 1,
                // `.some(nil)` clears the display string back to the raw number,
                // which is what dropping `format` has to mean.
                format: .some(props["format"]?.asString)
            )

        case .progress:
            guard let progress = view as? LedgeProgress else { return }
            progress.applyRate(props["rate"]?.asDouble)
            // Resolved, not optional: `configure` sees the merged prop set, so a
            // deleted `color` (null, §3.1) goes back to ink.
            progress.applyColor(Self.meterColor(props["color"]?.asString))
            if let value = props["value"]?.asDouble { progress.applyCommittedValue(value) }

        case .wing:
            // `side` is the only prop, it is validated on the wire (§3.1), and
            // `left` is the only value an app may send — so there is nothing
            // left for the renderer to decide.
            break

        case .mini, .summary:
            // No props at all on either swell node: what one shows is its
            // children, and *when* it shows is the shell's — `ctx.peek` for a
            // notification, a hover past Th for a summary. Deliberately not a
            // prop, so an app can neither pin the surface open by never
            // re-rendering nor take away the chevron the shell draws on it.
            break

        case .spinner:
            // Nothing to configure: a spinner has no state but "turning", and it
            // turns whenever it is on screen. An `update` op on one is not an
            // error — it just has nothing to do.
            break

        case .pill:
            guard let pill = view as? LedgePill else { return }
            pill.apply(
                text: props["label"]?.asString ?? "",
                tone: LedgePill.Tone(token: props["tone"]?.asString)
            )
        }
    }

    /// `segment.options` — `[{ id, label }]`. A member with no `id` is dropped
    /// rather than given a synthetic one: an unidentifiable segment could never be
    /// selected, and reporting `change` with an invented id would be a lie.
    private static func segmentOptions(_ value: JSONValue?) -> [LedgeSegment.Option] {
        (value?.asArray ?? []).compactMap { entry in
            guard let object = entry.asObject, let id = object["id"]?.asString else { return nil }
            return LedgeSegment.Option(id: id, label: object["label"]?.asString ?? id)
        }
    }

    /// `stack.align` — the **cross**-axis alignment (spec §5).
    ///
    /// The canonical words are the spec's and the JSX types': `leading` /
    /// `center` / `trailing`. `start` / `end` are kept as aliases because this
    /// switch only ever knew those two, so every documented `align="leading"`
    /// silently did nothing — a wrong word here is not an error anywhere, which
    /// is exactly why it survived. An unknown word still leaves the axis default
    /// alone rather than guessing.
    private func applyAlign(_ stack: NSStackView, _ align: String?) {
        guard let align else { return }
        let horizontal = stack.orientation == .horizontal
        switch align {
        case "leading", "start": stack.alignment = horizontal ? .top : .leading
        case "center": stack.alignment = horizontal ? .centerY : .centerX
        case "trailing", "end": stack.alignment = horizontal ? .bottom : .trailing
        default: break
        }
    }

    // MARK: - Helpers

    private func constrainSize(_ view: NSView, width: CGFloat, height: CGFloat) {
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    private func cgFloat(_ value: JSONValue?, default fallback: CGFloat) -> CGFloat {
        value?.asDouble.map { CGFloat($0) } ?? fallback
    }

    /// `button.variant` (spec §5). Four words reach an app: `plain`, `glass`,
    /// `accent` and **`ghost`** — the app-content tier of design.html §06's
    /// two-tier control law (bare pure-white glyph, a capsule only under the
    /// cursor). `bead` is deliberately *not* here: a bead is Ledge's own chrome,
    /// and an app that could name it would dress its buttons as the shell's.
    static func variant(_ raw: String?) -> LedgeButtonVariant {
        switch raw {
        case "glass": .glass
        case "accent": .accent
        case "ghost": .ghost
        default: .plain
        }
    }

    /// `stack.fill` tokens (spec §5 proposal). Semantic names only — an app
    /// that could name `#1B1B1B` would own the theme, and the shell couldn't
    /// restyle without breaking every app.
    static func fillToken(_ raw: String?) -> NSColor? {
        switch raw {
        case "raised": LedgeTheme.raised
        case "raisedHover": LedgeTheme.raisedHover
        case "accentTint": LedgeTheme.accentTint
        case "greenTint": LedgeTheme.greenTint
        case "redTint": LedgeTheme.redTint
        case "violetTint": LedgeTheme.violetTint
        case "black": LedgeTheme.sunken
        default: nil
        }
    }

    /// `stack.gradient` tokens (spec §5 proposal): a **standardized wash**, not
    /// a free-form gradient. The app names a hue family — the same five the
    /// tint and stroke sets already use — and the shell owns the geometry (top
    /// of the container at `washAlpha`, transparent by `washEnd`).
    ///
    /// That split is the whole design. A prop that took two colors, an angle
    /// and two stops would let every app invent its own material, and a row of
    /// panels would stop looking like one system after the second app. Inside a
    /// `canvas` the opposite rule applies — pixels are the app's, and the
    /// `gradient` draw op (§3.4) takes real colors and an angle.
    static func gradientToken(_ raw: String?) -> NSColor? {
        switch raw {
        case "accent": LedgeTheme.accent
        case "green": LedgeTheme.green
        case "red": LedgeTheme.red
        case "violet": LedgeTheme.violet
        case "cyan": LedgeTheme.cyan
        default: nil
        }
    }

    /// `stack.stroke` tokens (spec §5 proposal). Always a 1 pt hairline.
    static func strokeToken(_ raw: String?) -> NSColor? {
        switch raw {
        case "hairline": LedgeTheme.hairline
        case "accent": LedgeTheme.accentStroke
        case "green": LedgeTheme.greenStroke
        case "red": LedgeTheme.redStroke
        case "violet": LedgeTheme.violetStroke
        default: nil
        }
    }

    static func semanticColor(_ raw: String?, default fallback: NSColor = LedgeTheme.green) -> NSColor {
        switch raw {
        case "primary": LedgeTheme.primary
        case "secondary": LedgeTheme.secondary
        case "tertiary": LedgeTheme.tertiary
        case "green": LedgeTheme.green
        case "red": LedgeTheme.red
        case "accent": LedgeTheme.accent
        case "cyan": LedgeTheme.cyan
        case "violet": LedgeTheme.violet
        default: fallback
        }
    }

    /// `progress.color` (spec §5): the hue *families* a meter may take, and
    /// nothing else. Deliberately narrower than `semanticColor` — the ink
    /// shades (`primary`/`secondary`/`tertiary`) are not meter colours, they are
    /// type colours, and a meter that could name one would just be the default
    /// spelled three ways. Anything unrecognised, and absence, is ink.
    static func meterColor(_ raw: String?) -> NSColor {
        switch raw {
        case "accent": LedgeTheme.accent
        case "green": LedgeTheme.green
        case "red": LedgeTheme.red
        case "violet": LedgeTheme.violet
        case "cyan": LedgeTheme.cyan
        default: LedgeTheme.inkFill
        }
    }

    /// The `text` face for a §5 prop pair. The ramp itself is
    /// `LedgeMetrics.TypeSize`/`TypeWeight` — this only resolves tokens and
    /// picks the family, because a size ramp that only the protocol renderer
    /// can see is a ramp the shell's own chrome will fork.
    static func font(size: String?, weight: String?, mono: Bool) -> NSFont {
        let pointSize = LedgeMetrics.TypeSize(token: size).pointSize
        let fontWeight = LedgeMetrics.TypeWeight(token: weight).fontWeight
        // Non-mono text uses the *monospaced-digit* system font: the same
        // typeface as `systemFont`, but prices and percentages stop jittering
        // as they tick. Apps get that for free rather than asking for `mono`
        // and losing proportional letterforms.
        return mono
            ? LedgeTheme.monoFont(pointSize, weight: fontWeight)
            : LedgeTheme.numericFont(pointSize, weight: fontWeight)
    }
}
