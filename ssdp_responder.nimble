# Package

version       = "1.0.0"
author        = "SSDP Responder"
description   = "SSDP/UPnP responder for device discovery"
license       = "MIT"
srcDir        = "."
bin           = @["ssdp_responder"]

# Dependencies

requires "nim >= 2.2.0"
requires "multicast >= 0.1.5"
requires "uuidgen >= 0.1.0"