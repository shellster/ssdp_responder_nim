import std/[
  asyncdispatch,
  asynchttpserver,
  asyncnet,
  nativesockets,
  net,
  os,
  parseopt,
  random,
  strformat,
  strutils,
  times
]

import multicast
import uuidgen

const
  SSDP_MULTICAST_ADDR = "239.255.255.250"
  SSDP_PORT = 1900
  DEFAULT_HTTP_PORT = 49152
  SERVER_NAME = "UPnP/1.1 SsdpResponder/1.0"

type
  SsdpResponder = ref object
    hostname: string
    localIp: string
    httpPort: int
    uuid: string
    deviceType: string
    friendlyName: string
    manufacturer: string
    modelName: string

proc getDescriptionLocation(self: SsdpResponder): string =
  return &"http://{self.localIp}:{self.httpPort}/description.xml"

proc buildDescriptionXml(self: SsdpResponder): string =
  return &"""<?xml version="1.0" encoding="UTF-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <device>
    <deviceType>uuid:{self.uuid}:{self.deviceType}</deviceType>
    <friendlyName>{self.friendlyName}</friendlyName>
    <manufacturer>{self.manufacturer}</manufacturer>
    <modelName>{self.modelName}</modelName>
    <UDN>{self.hostname}</UDN>
  </device>
</root>"""

proc buildMSearchResponse(self: SsdpResponder, st: string): string =
  return "HTTP/1.1 200 OK\r\n" &
    "CACHE-CONTROL: max-age=1800\r\n" &
    "EXT:\r\n" &
    &"ST: {st}\r\n" &
    &"USN: uuid:{self.uuid}::{st}\r\n" &
    &"SERVER: {SERVER_NAME}\r\n" &
    &"LOCATION: {self.getDescriptionLocation()}\r\n" &
    "\r\n"

proc buildNotifyAlive(self: SsdpResponder): string =
  return "NOTIFY * HTTP/1.1\r\n" &
    &"HOST: {SSDP_MULTICAST_ADDR}:{SSDP_PORT}\r\n" &
    "CACHE-CONTROL: max-age=1800\r\n" &
    &"LOCATION: {self.getDescriptionLocation()}\r\n" &
    &"NT: {self.deviceType}\r\n" &
    "NTS: ssdp:alive\r\n" &
    &"SERVER: {SERVER_NAME}\r\n" &
    &"USN: uuid:{self.uuid}::{self.deviceType}\r\n" &
    "\r\n"

proc parseMSearch(data: string): tuple[valid: bool, st: string, mx: int] =
  result = (valid: false, st: "", mx: 3)

  let lines = data.split("\r\n")
  if lines.len == 0:
    return

  if not lines[0].toUpperAscii.startsWith("M-SEARCH "):
    return

  for i in 1..<lines.len:
    let line = lines[i]
    let colonPos = line.find(':')
    if colonPos > 0:
      let key = line[0..<colonPos].strip.toUpperAscii
      let value = line[colonPos+1..^1].strip

      case key
      of "ST":
        result.st = value
      of "MX":
        try:
          result.mx = parseInt(value)
        except ValueError:
          result.mx = 3

  result.valid = true

proc startHttpServer(self: SsdpResponder) {.async.} =
  let server = newAsyncHttpServer()

  proc callback(req: Request) {.async, gcsafe.} =
    let path = req.url.path
    echo &"[HTTP] {req.reqMethod} {path} from {req.hostname}"

    case path
    of "/description.xml", "/":
      let xml = self.buildDescriptionXml()
      let headers = newHttpHeaders([
        ("Content-Type", "text/xml; charset=utf-8"),
        ("Connection", "close")
      ])
      await req.respond(Http200, xml, headers)
    else:
      await req.respond(Http404, "Not Found")

  echo &"[HTTP] Starting HTTP server on port {self.httpPort}"
  echo &"[HTTP] Description URL: http://{self.localIp}:{self.httpPort}/description.xml"
  await server.serve(Port(self.httpPort), callback)

proc startSsdpListener(self: SsdpResponder) {.async.} =
  let socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
      Protocol.IPPROTO_UDP)
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(Port(SSDP_PORT))

  if not socket.joinGroup(SSDP_MULTICAST_ADDR):
    echo "could not join multicast group"
    quit()

  defer: discard socket.leaveGroup(SSDP_MULTICAST_ADDR)

  socket.enableBroadcast(true)

  echo &"[SSDP] Listening on {SSDP_MULTICAST_ADDR}:{SSDP_PORT}"
  echo &"[SSDP] Advertising hostname: {self.hostname}"
  echo &"[SSDP] Local IP: {self.localIp}"
  echo &"[SSDP] Device UUID: {self.uuid}"

  var rng = initRand()

  while true:
    try:
      let (data, address, port) = await socket.recvFrom(1500)

      if data.len > 0:
        let parsed = parseMSearch(data)

        if parsed.valid:
          if parsed.st in ["ssdp:all", "upnp:rootdevice",
              &"uuid:{self.uuid}:{self.deviceType}"]:
            echo &"[SSDP] M-SEARCH from {address}:{port} ST={parsed.st}"
            await sleepAsync(rng.rand(min(parsed.mx * 1000, 5000)))

            let response = self.buildMSearchResponse(parsed.st)

            let responseSocket = newAsyncSocket(Domain.AF_INET,
                SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
            try:
              await responseSocket.sendTo(address, port, response)
            finally:
              responseSocket.close()

            echo &"[SSDP] Sent response to {address}:{port}"
    except CatchableError as e:
      echo &"[SSDP] Error: {e.msg}"

proc sendNotifyAlive(self: SsdpResponder) {.async.} =
  let socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM,
      Protocol.IPPROTO_UDP)
  defer: socket.close()

  while true:
    try:
      let notify = self.buildNotifyAlive()
      await socket.sendTo(SSDP_MULTICAST_ADDR, Port(SSDP_PORT), notify)
    except CatchableError as e:
      echo &"[SSDP] Error sending NOTIFY: {e.msg}"

    await sleepAsync(30000)

proc run(self: SsdpResponder) =
  echo "Starting SSDP Responder..."
  echo "=========================="

  waitFor self.sendNotifyAlive() and self.startSsdpListener() and
      self.startHttpServer()

proc printUsage() =
  echo """
SSDP Responder

Usage: ssdp_responder [options]

Options:
  -h, --hostname <name>    Hostname to advertise (required)
  -p, --port <port>        HTTP port for description.xml (default: 49152)
  -n, --name <name>        Friendly device name
  -m, --manufacturer <name> Manufacturer name
  --model <name>           Model name
  --help                   Show this help

Example:
  ssdp_responder -h mydevice.local -p 8080 -n "My Device"
"""

proc main() =
  var hostname = ""
  var httpPort = DEFAULT_HTTP_PORT
  var friendlyName = ""
  var manufacturer = "Unknown"
  var modelName = "Unknown"

  var p = initOptParser(commandLineParams())

  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key.toLowerAscii
      of "h", "hostname":
        hostname = p.val
      of "p", "port":
        try:
          httpPort = parseInt(p.val)
        except ValueError:
          echo "Error: Invalid port number"
          quit(1)
      of "n", "name":
        friendlyName = p.val
      of "m", "manufacturer":
        manufacturer = p.val
      of "model":
        modelName = p.val
      of "help":
        printUsage()
        quit(0)
      else:
        echo &"Unknown option: {p.key}"
        printUsage()
        quit(1)
    of cmdArgument:
      if hostname.len == 0:
        hostname = p.key

  if hostname.len == 0:
    echo "Error: Hostname is required"
    printUsage()
    quit(1)

  let responder = SsdpResponder(
    hostname: hostname,
    localIp: $getPrimaryIPAddr(),
    httpPort: httpPort,
    uuid: $newUuidv4(),
    deviceType: "urn:schemas-upnp-org:device:Basic:1",
    friendlyName: if friendlyName.len > 0: friendlyName else: hostname,
    manufacturer: manufacturer,
    modelName: modelName
  )

  responder.run()

when isMainModule:
  main()
