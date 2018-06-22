## Intel Hex parsing and utility library
## Copyright 2018 KeyMe Inc

## This library includes basic utilities for dealing with intel hex
## files, which are commonly used for the distribution of
## microcontroller firmware binaries due to their inclusion of address
## and data information in a single easy to parse text format. For
## more information about the intel hex format, see
## https://en.wikipedia.org/wiki/Intel_HEX

import math
import strutils
import options
import strformat
import sequtils

type
  RowType* = enum
    rtData = 0x00,
    rtEOF = 0x01
    rtExtSegAddr = 0x02
    rtStartSegAddr = 0x03
    rtExtLinAddr = 0x04
    rtStartLinAddr = 0x05

  HexDecodeError* = object of Exception
  RowSizeError* = object of Exception

  AddressedData*[T] = object
    address*: uint32
    data*: T

  AddressedU32* = AddressedData[uint32]
  AddressedByte* = AddressedData[byte]

  HexRow* = ref object
    rowType*: RowType
    offset*: uint16
    byteCount*: byte
    bytes*: seq[byte]
    checksum*: byte

  HexAddrGroup* = ref object
    addrRow*: HexRow
    dataRows*: seq[HexRow]

  HexFile* = ref object
    addrGroups*: seq[HexAddrGroup]

const
  DefaultAddrGroup = ":020000000000FE"
  AddrSpaceSize = 0x10000.uint32
  MaxRowSize = 0xff
  RowChunkSize = 16


iterator chunksOf[T](s: openarray[T], size: int): seq[T] =
  ## Yields even sized chunks of the input array. If there are an
  ## uneven number of units at the end of the buffer, the last chunk
  ## will simply be the remainder.

  ## e.g. [1..10].chunksOf(3) => @[1, 2, 3] @[4, 5, 6] @[7, 8, 9] @[10]
  if s.high == -1:
    # Yield an empty seq for empty input
    yield @[]
  else:
    for sliceStart in countUp(0, s.high, size):
      let sliceEnd = min(s.high, sliceStart + size - 1)
      yield s[sliceStart..sliceEnd]

proc checksum*(data: openarray[byte]): byte =
  result = ((sum(data) xor 0xff) + 1) and 0xff

proc checksum*(hr: HexRow): uint8 =
  result = checksum(@[hr.byteCount,
                      hr.rowType.byte,
                      (hr.offset shr 8).byte,
                      (hr.offset and 0xff).byte] & hr.bytes).byte

proc `$`*(hr: HexRow): string =
  var dataStr = ""
  for b in hr.bytes:
    dataStr &= &"{b:02X}"
  result = &":{hr.byteCount:02X}{hr.offset:04X}{hr.rowType.byte:02X}{dataStr}{hr.checksum:02X}"

proc `$`*(hag: HexAddrGroup): string =
  result = hag.dataRows.map(proc(x: HexRow): string = $x).join("\n")

proc `$`*(hf: HexFile): string =
  result = hf.addrGroups.map(proc(x: HexAddrGroup): string = $x).join("\n")

proc validate(hr: HexRow) =
  assert checksum(hr) == hr.checksum

proc fromStr*(s: string): HexRow =
  ## Parses a row of iHex data into a corresponding object
  var s = strip(s)

  if s[0] != ':':
    raise newException(HexDecodeError, &"Invalid row start: {s[0]}")

  new(result)
  result.byteCount = parseHexInt(s[1..2]).byte
  result.offset = parseHexInt(s[3..6]).uint16
  result.rowType = parseHexInt(s[7..8]).RowType
  result.checksum = parseHexInt(s[^2..^1]).byte

  result.bytes = @[]

  let workingRow = s[9..< ^2]
  for chunk in workingRow.chunksof(2):
    let chunkStr = chunk.join("")
    result.bytes.add(parseHexInt(chunkStr).byte)

  result.validate()

proc fromBytes*(bytes: openarray[byte], offset: uint16,
                rowType: RowType): HexRow =
  ## Given binary data, an offset, and a rowType, generates a HexRow
  ## object which can then be serialized to a binary string or ASCII
  ## hex row
  new(result)
  if len(bytes) > MaxRowSize:
    raise newException(RowSizeError, &"Too many bytes({len(bytes)}) in row")
  result.byteCount = len(bytes).byte
  result.bytes = @bytes
  result.rowType = rowType
  result.offset = offset
  result.checksum = checksum(result)

  validate(result)

proc getBaseOffset*(hag: HexAddrGroup): uint32 =
  result = ((hag.addrRow.bytes[0].uint32 shl 24) or
            (hag.addrRow.bytes[1].uint32 shl 16))

proc toByteList*(hag: HexAddrGroup): seq[AddressedByte] =
  result = @[]
  let baseOffset = hag.getBaseOffset()
  for row in hag.dataRows:
    if row.rowType != rtData:
      continue
    var rowOffset = row.offset
    for b in row.bytes:
      result.add(AddressedByte(address: baseOffset or rowOffset, data: b))
      inc(rowOffset)

proc toU32List*(hf: HexFile): seq[AddressedU32] =
  result = @[]
  var byteList = newSeq[AddressedByte]()

  for ag in hf.addrGroups:
    byteList &= ag.toByteList()

  for chunk in byteList.chunksOf(4):
    let wordOffset = chunk[0].address
    var word: uint32 = 0
    for i in 0..chunk.high:
      word = word or (chunk[i].data shl (8 * (3 - i)))

    result.add(AddressedU32(address: wordOffset, data: word))

proc newHexAddrGroup*(): HexAddrGroup =
  new(result)
  result.dataRows = @[]

proc newHexAddrGroup*(addrRow: HexRow): HexAddrGroup =
  result = newHexAddrGroup()
  result.addrRow = addrRow

proc `+=`*(hag: HexAddrGroup, hr: HexRow) =
  hag.dataRows.add(hr)

proc `+=`*(hf: HexFile, hag: HexAddrGroup) =
  hf.addrGroups.add(hag)

proc `+=`*(hf: HexFile, hr: HexRow) =
  hf.addrGroups[^1] += hr

proc newHexFile(): HexFile =
  new(result)
  result.addrGroups = @[]

proc fromHexFile*(path: string): HexFile =
  result = newHexFile()

  for line in lines(path):
    let row: HexRow = fromStr(line)

    if row.rowType == rtExtLinAddr:
      let ag = newHexAddrGroup(row)
      result.addrGroups.add(ag)
    else:
      # For things like AVR which only have a 16 bit address
      # space and therefore don't need to place their code
      # at a deep offset, we need to create a default
      # address group starting at 0
      if len(result.addrGroups) == 0:
        let defaultRow = fromStr(DefaultAddrGroup)
        let ag = newHexAddrGroup(defaultRow)
        result.addrGroups.add(ag)
      result.addrGroups[^1] += row

proc addAddrGroupFromOffset(hf: HexFile, offset: uint16) =
  let ar = fromBytes(
    [(offset shr 8).byte, (offset and 0xff).byte],
    0,
    rtExtLinAddr
  )
  hf += newHexAddrGroup(ar)


proc fromBinaryFile*(path: string, baseOffset: uint32): HexFile =
  result = newHexFile()

  let binData = readFile(path).map(proc (x: char):byte = x.byte)

  var offset = (baseOffset and 0xffff).uint32
  var baseOffset = (baseOffset shr 16).uint16

  result.addAddrGroupFromOffset(baseOffset)

  baseOffset += 1
  var startIdx: uint32 = 0

  while startIdx < len(binData).uint32:
    let remainingSpace = AddrSpaceSize - offset
    if remainingSpace == 0:
      result.addAddrGroupFromOffset(baseOffset)
      offset = 0
      inc(baseOffset)
      continue
    let endIdx = min(startIdx + remainingSpace, len(binData).uint32)
    let workingBlock = binData[startIdx..<endIDX]
    for chunk in workingBlock.chunksOf(RowChunkSize):
      let dataRow: HexRow = fromBytes(chunk, offset.uint16, rtData)
      result += dataRow
      offset += len(chunk).uint32
    startIdx += remainingSpace

  let endRow: HexRow = fromBytes([], 0, rtEOF)
  result += endRow


proc asBinaryString*(hr: HexRow): string =
  return hr.bytes.map(proc(x: byte): string =
                          x.toHex().parseHexStr()).join("")

proc asBinaryString*(hag: HexAddrGroup): string =
  return hag.datarows.map(proc(hr: HexRow): string =
                              hr.asBinaryString()).join("")

proc asBinaryString*(hf: HexFile): string =
  return hf.addrGroups.map(proc(hag: HexAddrGroup): string =
                               hag.asBinaryString()).join("")

proc saveBinaryFile*(hf: HexFile, path: string) =
  # The slice at the end prevents the terminating '\00' from being
  # written to the output file
  writeFile(path, hf.asBinaryString()[0..^2])

proc saveHexFile*(hf: HexFile, path: string) =
  writeFile(path, $hf)
