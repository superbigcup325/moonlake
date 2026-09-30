///|
/// Entry point for the `moonlake` CLI.
/// Run with `moon run cmd/main` from the project root.
fn main {
  let args = @env.args()
  if args.contains("--version") {
    println("moonlake \{@moonlake.version()}")
    return
  }
  println(usage())
}

///|
fn usage() -> String {
  (
    #|moonlake - embeddable analytical query engine for MoonBit
    #|
    #|Usage: moonlake [options]
    #|
    #|Options:
    #|  --version   Print version and exit
    #|  --help      Print this help and exit
    #|
    #|SQL execution commands are under active development.
  )
}

///|
test {
  assert_true(usage().contains("moonlake"))
}
