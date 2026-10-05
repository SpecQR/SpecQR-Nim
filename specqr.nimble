version = "0.1.0"
author = "SpecQR contributors"
description = "From-scratch, standard-library-only QR Model 2 encoder"
license = "MIT"
srcDir = "src"
bin = @["specqr_cli"]
requires "nim >= 2.2.0"

# Install library modules as well as the CLI on older Nimble versions.
installExt = @["nim"]
