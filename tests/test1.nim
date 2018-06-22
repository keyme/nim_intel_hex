import intel_hex
import os
import unittest
import strformat
import ospaths

suite "iHex Round Trip":
  test "Test low offset":
    let startingOffset = 0x08004000.uint32
    var workingOffset = startingOffset

    let bf = fromBinaryFile("tests/main.bin", startingOffset)
    let bfList = bf.toU32List()

    for w in bfList:
      assert w.address == workingOffset
      workingOffset += 4

  test "Test high offset":
    let startingOffset = 0x08020000.uint32
    var workingOffset = startingOffset

    let bf = fromBinaryFile("tests/main.bin", startingOffset)
    let bfList = bf.toU32List()

    for w in bfList:
      assert w.address == workingOffset
      workingOffset += 4

  test "Test ARM GCC output":
    let startingOffset = 0x08004000.uint32

    let hf = fromHexFile("tests/main.hex")
    let bf = fromBinaryFile("tests/main.bin", startingOffset)

    let hfList = hf.toU32List()
    let bfList = bf.toU32List()

    assert len(hfList) == len(bfList)
    for i in 0..hfList.high:
      assert hfList[i].address == bfList[i].address


  test "Test AVR GCC output":
    let startingOffset = 0x00.uint32
    let hf = fromHexFile("tests/grbl.hex")
    let bf = fromBinaryFile("tests/grbl.bin", startingOffset)

    let hfList = hf.toU32List()
    let bfList = bf.toU32List()

    assert len(hfList) == len(bfList)
    for i in 0..hfList.high:
      assert hfList[i].address == bfList[i].address

  test "Test empty binary string output":
    let endRow: HexRow = fromBytes([], 0, rtEOF)
    assert endRow.asBinaryString() == ""

  test "Test data binary string output":
    let dataRow: HexRow = fromBytes([0.byte, 1.byte, 2.byte, 3.byte], 0, rtData)
    let dfByteString = dataRow.asBinaryString()
    assert dfByteString == "\0\1\2\3"

  test "Test save binary round trip":
    let outDir = getTempDir()

    let hf = fromHexFile("tests/grbl.hex")
    let bf = fromBinaryFile("tests/grbl.bin", 0x00)
    hf.saveBinaryFile(outDir / "grbl_1.bin")
    let bf2 = fromBinaryFile(outDir / "grbl_1.bin", 0x00)

    let bf1List = bf.toU32List()
    let bf2List = bf2.toU32List()

    assert len(bf1List) == len(bf2List)
    for i in 0..bf1List.high:
      assert bf1List[i].address == bf2List[i].address
      assert bf1List[i].data == bf2List[i].data

  test "Test save hex round trip":
    let outDir = getTempDir()

    let hf = fromHexFile("tests/grbl.hex")
    let bf = fromBinaryFile("tests/grbl.bin", 0x00)

    bf.saveHexFile(outDir / "grbl_1.hex")
    let hf2 = fromHexFile(outDir / "grbl_1.hex")

    let hf1List = hf.toU32List()
    let hf2List = hf2.toU32List()

    assert len(hf1List) == len(hf2List)
    for i in 0..hf1List.high:
      assert hf1List[i].address == hf2List[i].address
      assert hf1List[i].data == hf2List[i].data
