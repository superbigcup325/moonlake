// moonlake - embeddable analytical query engine for MoonBit.
// Root package: engine facade. Sub-packages arrive with the v1 milestones.

///|
/// Version of the `superbigcup325/moonlake` module, kept in sync with `moon.mod`.
pub const VERSION : String = "0.1.0"

///|
/// Short human-readable description of the module.
pub const DESCRIPTION : String = "Embeddable analytical query engine for MoonBit"

///|
/// Returns the engine version string.
pub fn version() -> String {
  VERSION
}
