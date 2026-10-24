// Run this package's vite build and exit as soon as bundling finishes.
//
// Under Termux/Bionic, vite's `build()` promise never resolves once the parent
// process imports `effect`: the bundling completes and writes dist/, but the
// async cleanup (rolldown workers, temp files) rides a thread pool that the
// effect runtime leaves un-drained, so the promise hangs forever. Waiting on
// `build()` therefore deadlocks the CLI build.
//
// Instead we hook vite's own `closeBundle`, which fires after the bundle is
// written, and exit there. The output on disk is complete at that point.
import { build } from "vite"

await build({
  plugins: [
    {
      name: "opencode-exit-after-bundle",
      closeBundle() {
        process.exit(0)
      },
    },
  ],
})
process.exit(0)
