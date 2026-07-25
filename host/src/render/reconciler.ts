// The Ledge React renderer: a mutation-mode react-reconciler host config that
// emits spec §3.1 commit batches to a MutationSink instead of touching any
// real view system. Runs in the app worker; tests run it against an
// in-memory sink with no socket or AppKit anywhere.

import ReactReconciler from "react-reconciler";
import { DefaultEventPriority } from "react-reconciler/constants";
import type { ReactNode } from "react";
import type { Mutation, MutationSink, Props } from "./mutations";
import { HandlerRegistry, diffProps, serializeProps } from "./props";

export interface Instance {
  id: number;
  kind: string;
  props: Props;
}

interface Container {
  rootId: number | null;
}

type UpdatePayload = Props;

export interface LedgeRenderer {
  /** Renders (or re-renders) the element tree; each React commit emits one
   * mutation batch to the sink. */
  render(element: ReactNode): void;
  /** Unmounts the tree (emits the final removes). */
  unmount(): void;
  /** Routes a shell event to the registered handler prop; false when stale. */
  dispatchEvent(id: number, name: string, data?: Record<string, unknown>): boolean;
}

export function createLedgeRenderer(sink: MutationSink): LedgeRenderer {
  const registry = new HandlerRegistry();
  // Ids are allocated per renderer session and never reused (spec §3.1).
  let nextId = 1;
  // The current commit's batch. createInstance runs in the render phase, but
  // the worker renders synchronously (legacy root), so batching per
  // prepareForCommit..resetAfterCommit holds together.
  let batch: Mutation[] = [];

  const reconciler = ReactReconciler<
    string, // Type
    Props, // Props
    Container,
    Instance,
    never, // TextInstance — raw text is a spec error, use <text content=…>
    never, // SuspenseInstance
    never, // HydratableInstance
    Instance, // PublicInstance
    null, // HostContext
    UpdatePayload,
    never, // ChildSet
    ReturnType<typeof setTimeout>, // TimeoutHandle
    -1 // NoTimeout
  >({
    supportsMutation: true,
    supportsPersistence: false,
    supportsHydration: false,
    isPrimaryRenderer: true,
    noTimeout: -1,
    scheduleTimeout: setTimeout,
    cancelTimeout: clearTimeout,

    getRootHostContext: () => null,
    getChildHostContext: (parentContext) => parentContext,
    getPublicInstance: (instance) => instance,
    shouldSetTextContent: () => false,

    createInstance: (type, props) => {
      const instance: Instance = { id: nextId++, kind: type, props };
      batch.push({
        op: "create",
        id: instance.id,
        kind: type,
        props: serializeProps(instance.id, props, registry),
      });
      return instance;
    },

    createTextInstance: (text): never => {
      throw new Error(
        `raw text ${JSON.stringify(text)} is not renderable — use <text content={…}/>`,
      );
    },

    appendInitialChild: (parent, child) => {
      batch.push({ op: "insert", parent: parent.id, id: child.id, before: null });
    },
    appendChild: (parent, child) => {
      batch.push({ op: "insert", parent: parent.id, id: child.id, before: null });
    },
    insertBefore: (parent, child, before) => {
      batch.push({ op: "insert", parent: parent.id, id: child.id, before: before.id });
    },
    removeChild: (_parent, child) => {
      registry.removeInstance(child.id);
      batch.push({ op: "remove", id: child.id });
    },

    appendChildToContainer: (container, child) => {
      container.rootId = child.id;
      batch.push({ op: "setRoot", id: child.id });
    },
    insertInContainerBefore: (container, child) => {
      container.rootId = child.id;
      batch.push({ op: "setRoot", id: child.id });
    },
    removeChildFromContainer: (container, child) => {
      registry.removeInstance(child.id);
      batch.push({ op: "remove", id: child.id });
      if (container.rootId === child.id) container.rootId = null;
    },
    clearContainer: (container) => {
      container.rootId = null;
    },

    finalizeInitialChildren: () => false,
    prepareUpdate: (instance, _type, oldProps, newProps) =>
      diffProps(instance.id, oldProps, newProps, registry),
    commitUpdate: (instance, patch, _type, _oldProps, newProps) => {
      instance.props = newProps;
      batch.push({ op: "update", id: instance.id, props: patch });
    },
    commitTextUpdate: () => {},
    resetTextContent: () => {},

    prepareForCommit: () => null,
    resetAfterCommit: () => {
      if (batch.length > 0) {
        sink.commit(batch);
        batch = [];
      }
    },
    preparePortalMount: () => {},
    detachDeletedInstance: () => {},

    getCurrentEventPriority: () => DefaultEventPriority,
    getInstanceFromNode: () => null,
    getInstanceFromScope: () => null,
    beforeActiveInstanceBlur: () => {},
    afterActiveInstanceBlur: () => {},
    prepareScopeUpdate: () => {},
  });

  const container: Container = { rootId: null };
  // Legacy (synchronous) root: the worker has no interactive scheduling needs
  // and sync commits keep one render = one wire batch.
  const root = reconciler.createContainer(
    container,
    0,
    null,
    false,
    null,
    "ledge",
    (error) => {
      throw error;
    },
    null,
  );

  return {
    render(element) {
      reconciler.updateContainer(element, root, null, null);
    },
    unmount() {
      reconciler.updateContainer(null, root, null, null);
    },
    dispatchEvent(id, name, data = {}) {
      return registry.dispatch(id, name, data);
    },
  };
}
