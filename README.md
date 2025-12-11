# ssdp_responder_nim
Simple SSDP (UPnP) Responder, written in Nim

I mostly wrote this for two reasons:

1) To learn Nim better.
2) For a simple way to advertise the IP's of various devices on my network.

I make no guarantees that this is the "right" way to do anything in Nim.
It almost certainly violates some/many parts of the UPnP RFC, but it works for my purposes.

## Build

If you have `just`, you can run `just build` assuming you have `nim`, `nimble`, and `strip` in your path.

If not, look at the commands in `.justfile` and manually run them after modifying appropriately.

