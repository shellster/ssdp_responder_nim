build:
  nimble install
  nimble c -d:release --threads:off --opt:size ./ssdp_responder.nim
  strip ./ssdp_responder
