// Where the sun is, for a given instant and a given place.
//
// This is the scrubber's payoff: drag the ruler and the light in the pane swings
// because the sun actually moved, not because a curve was hand-drawn. It is the
// low-precision NOAA/Meeus solar position — good to a fraction of a degree,
// which is three orders of magnitude better than a pane 412 points wide needs.
//
// Nothing here knows about weather or pixels. `pane.js` turns an elevation and
// an azimuth into light.

const RAD = Math.PI / 180;
const DEG = 180 / Math.PI;

/** Days since the J2000.0 epoch (2000-01-01 12:00 UTC), the zero every term below is written against. */
function j2000Days(ms) {
  return ms / 86_400_000 + 2_440_587.5 - 2_451_545.0;
}

/**
 * Sun position as seen from `lat`/`lon` at epoch-ms `ms`.
 *
 * @returns `{ elevation, azimuth }` in degrees — elevation above the true
 * horizon (negative at night), azimuth clockwise from north (0 N, 90 E, 180 S).
 */
export function solarPosition(ms, lat, lon) {
  const n = j2000Days(ms);

  // The sun's apparent ecliptic longitude: mean longitude, corrected by the
  // first two terms of the equation of centre.
  const meanLongitude = (280.46 + 0.9856474 * n) * RAD;
  const meanAnomaly = (357.528 + 0.9856003 * n) * RAD;
  const lambda =
    meanLongitude + (1.915 * Math.sin(meanAnomaly) + 0.02 * Math.sin(2 * meanAnomaly)) * RAD;
  const obliquity = (23.439 - 0.0000004 * n) * RAD;

  // …to equatorial coordinates.
  const declination = Math.asin(Math.sin(obliquity) * Math.sin(lambda));
  const rightAscension = Math.atan2(Math.cos(obliquity) * Math.sin(lambda), Math.cos(lambda));

  // …to the observer's sky. GMST in hours, then the local hour angle: how far
  // past the meridian the sun is, positive to the west.
  const gmstHours = 18.697375 + 24.065709824419 * n;
  const localSidereal = (gmstHours * 15 + lon) * RAD;
  const hourAngle = localSidereal - rightAscension;

  const phi = lat * RAD;
  const sinAltitude =
    Math.sin(phi) * Math.sin(declination) +
    Math.cos(phi) * Math.cos(declination) * Math.cos(hourAngle);

  // Azimuth measured from *south*, westward positive — the form that stays well
  // conditioned at high latitudes — then rotated onto the compass.
  const fromSouth = Math.atan2(
    Math.sin(hourAngle),
    Math.cos(hourAngle) * Math.sin(phi) - Math.tan(declination) * Math.cos(phi),
  );

  return {
    elevation: Math.asin(Math.max(-1, Math.min(1, sinAltitude))) * DEG,
    azimuth: (fromSouth * DEG + 180 + 360) % 360,
    // −180…180: how far past the meridian, in degrees. Fifteen per hour.
    hourAngle: ((hourAngle * DEG + 540) % 360) - 180,
  };
}

/** How much of the arc, either side of noon, the pane's width covers. Beyond
 * this the sun is behind you and its light only rakes the far edge — which is
 * exactly what the clamp produces. */
const ARC_DEGREES = 110;

/**
 * Where the sun sits *on the glass*, as `{ across, up }` in 0…1 from the pane's
 * top-left.
 *
 * A window faces one way and the app has no compass, so the honest mapping is
 * the daily arc itself: the hour angle, not the azimuth. Noon is the middle of
 * the pane, morning is one edge and evening the other, at every latitude and in
 * both hemispheres — where the naive "face south" rule quietly loses the sun off
 * the side of a tropical pane in summer, when it passes *north* of the zenith.
 */
export function sunOnPane(ms, lat, lon) {
  const sun = solarPosition(ms, lat, lon);
  const swing = Math.max(-1, Math.min(1, sun.hourAngle / ARC_DEGREES));
  // Southern hemisphere: the arc runs the other way across a poleward window.
  const across = 0.5 + (lat >= 0 ? swing : -swing) / 2;
  // Elevation 0 sits just below the sill, 70° at the top of the light.
  const up = Math.max(-0.15, Math.min(1.05, sun.elevation / 70));
  return { ...sun, across, up };
}
