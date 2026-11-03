-- CONFIG: Grenade (kind = throwable). Side: read by the client (WeaponConfig -> WeaponThrowable) and by the
-- server (WeaponGrenadeServer, which re-requires this module and never trusts client numbers).
-- No Enum is needed: there is no reload and no fire mode.
-- AMMO FIELDS: maxAmmo is the grenade count (3). limitedAmmo/storedAmmo exist so the shared ammo
--   plumbing (WeaponConfig.Apply, HUD) works; the HUD shows the count in the magazine slot and "-" as reserve.
--   The count is not refilled until the player respawns (the server resets the per-player count on death/respawn).
-- DAMAGE: linear falloff from `damage` at the blast centre to `edgeDamage` at `radius` (studs), applied by
--   the server after a line-of-sight check; Players carrying a "Protect" child are skipped.
-- TIMING: `fuse` seconds after the throw, `cooldown` seconds between throws.
-- THROW (hold right mouse to charge, release to throw):
--   chargeTime     seconds of holding for a full charge (client only; the server receives the 0..1 charge).
--   minThrowSpeed  launch speed (studs/s) at charge 0 (a tap, or a hold shorter than 0.1 s).
--   throwSpeed     launch speed at charge 1 (the maximum); speed = minThrowSpeed + (throwSpeed - minThrowSpeed) * charge.
--   throwPitchDeg  fixed launch elevation in degrees (5..80). The yaw is the camera yaw; the pitch never follows the
--                  camera, so the preview arc and the real throw are the same curve. At g = 85 a 40 degree throw
--                  reaches about 5 studs at minThrowSpeed 20 and about 35 studs at throwSpeed 55
--                  (flat ground: range = v^2 * sin(2 * pitch) / g).
--   The server recomputes the velocity from these numbers and the received charge; the client never sends a speed.
--   `throwUp` is no longer read (the old "add upward speed to the aim ray" throw is gone); it is kept only so an
--   older copy of the scripts that still reads it does not break.
-- How to test: hold right mouse with the Grenade equipped (an arc and a landing marker appear), release to throw,
--   HUD count drops 3 -> 2 -> 1 -> 0, a second throw within 1 s is ignored, the blast hurts the practice NPCs
--   and does nothing to a protected player. Left click does nothing.
return {
    kind = "throwable",

    limitedAmmo = true,
    maxAmmo = 3,
    storedAmmo = 0,

    damage = 90,
    edgeDamage = 20,
    radius = 12,

    fuse = 2.5,
    cooldown = 1,

    chargeTime = 1.2,
    minThrowSpeed = 20,
    throwSpeed = 55,
    throwPitchDeg = 40,
    throwUp = 6
}
