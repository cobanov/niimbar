# NIIMBOT B1 protocol (USB serial)

Primary source: `MultiMote/niimbluelib` @ `a9bc3f5` (2026-10-14). All `src/...:N` citations refer to that repo.
Secondary sources: `MultiMote/niimblue` @ `82c5605` (the web app that uses the lib), `AndBondStyle/niimprint`, `labbots/NiimPrintX`.
Everything multi-byte is **big-endian** (`src/packets/data_reader.ts:4`, `src/utils/utils.ts:157-161`). The one exception is the "total" pixel count (§6.4).

---

## 1. Transport

- 115200 baud, 8N1, no flow control (`src/client/serial_impl.ts:39`, `niimprint/printer.py:78`).
- Before **every** write, niimbluelib sleeps `packetIntervalMs = 10` ms (`src/client/abstract_client.ts:38-41,75`, `src/client/serial_impl.ts:121`). That includes each one-way bitmap row. The interval exists because of flow control problems (niimblue issue #5, cited at `abstract_client.ts:74`).
- All request/response exchanges go through one mutex, so there is never more than one request in flight (`abstract_client.ts:134-144`).
- Receive side: append each chunk to a buffer. If the buffer has more than 1 byte and doesn't start with `55 55`, drop the whole buffer. Otherwise try to split it into complete packets. On success, emit them and clear the buffer. On an incomplete packet, keep accumulating (`abstract_client.ts:200-233`, `src/packets/packet_parser.ts:33-102`).

## 2. Framing and checksum

```
55 55 | CMD | LEN | DATA[LEN] | CHK | AA AA
CHK = CMD ^ LEN ^ DATA[0] ^ ... ^ DATA[LEN-1]
```
- `src/packets/packet.ts:11-12` (head/tail), `:72-78` (checksum), `:80-120` (toBytes), `:122-159` (fromBytes validates head, size, tail and checksum).
- LEN is a single byte, so DATA can be at most 255 bytes.
- **Connect (0xC1) only**: the whole frame gets a leading `0x03`, giving `03 55 55 c1 01 01 c1 aa aa` (`packet.ts:112-117`).
- A command with no meaningful argument sends `DATA = [0x01]` (`src/packets/packet_generator.ts:39`).
- CRC32 framing (`packet.ts:171-287`) is used only for firmware upgrade (cmds 0x90-0x9E). You can ignore it.

Verified against real B1 traffic: `55 55 40 01 0a 4b aa aa` (GET_INFO battery) and `55 55 dc 01 04 d9 aa aa` (`src/test/dumps.ts:4-30`).

## 3. Response matching and errors

- Each request has a set of acceptable response IDs (`src/packets/commands.ts:171-245`). The receiver waits for the first packet whose ID is in that set and ignores any other packet that arrives meanwhile (`abstract_client.ts:155-194`).
- Two packets end any wait early, even when not in the set (`abstract_client.ts:167-181`):
  - `0xDB` In_PrintError: DATA = `[errorCode]` (1 byte). Codes are listed in §11.
  - `0x00` In_NotSupported: the command isn't supported.
- Row packets `0x83/0x84/0x85` are **one-way**. Don't wait for a reply; just apply the 10 ms gap (`commands.ts:173-176`, `abstract_client.ts:138-140`).
- Boolean replies (PageStart, PageEnd, PrintEnd): `DATA[0] == 1` means accepted, `0` means refused (`packet_parser.ts:353-356`, `src/packets/protocol.ts:435-452`). niimbluelib doesn't check the DATA of SetDensity, SetLabelType, PrintStart or SetPageSize replies; receiving the right ID counts as success.

## 4. Command table (what a B1 app needs)

| Cmd | Name | Request DATA | Response ID | Response DATA | Source |
|---|---|---|---|---|---|
| `C1` | Connect | `01` (frame prefixed by `03`) | `C2` | `[result]`: 1=Connected, 2=ConnectedNew (proto v1), 3=ConnectedV3, 90=FirmwareErrors | `commands.ts:9`, `enumerations.ts:93-99`, `protocol.ts:319-337` |
| `A5` | PrinterStatusData | `01` | `B5` | ≥13 bytes: `supportColor = D[10]>0`; `n = D[11]*100 + D[12]`: 204..299 means proto v3, 300..301 means v4, ≥302 means v5 | `packet_parser.ts:126-147` |
| `40` | GetInfo | `[key]` (§4.1) | `40+key` | depends on key (§4.1) | `packet_generator.ts:75-77`, `commands.ts:187-201` |
| `DC` | Heartbeat | `[type]` 1, 3 or 4 | `DD` / `DE` / `D9` | §8 | `packet_generator.ts:87-89` |
| `1A` | RfidInfo (label roll) | `01` | `1B` | §9 | `packet_generator.ts:59-61`, `packet_parser.ts:160-195` |
| `59` | GetPaperInfo | `01` | `69` | §9.2 | `packet_parser.ts:368-403` |
| `21` | SetDensity | `[density]` 1..5 | `31` | ignored | `packet_generator.ts:91-93` |
| `23` | SetLabelType | `[type]` (§10) | `33` | ignored | `packet_generator.ts:95-97` |
| `01` | PrintStart (7-byte, B1) | `[totalPages u16][00 00 00 00][pageColor=00]` | `02` | ignored | `packet_generator.ts:203-213` |
| `03` | PageStart | `01` | `04` | bool | `packet_generator.ts:224-226` |
| `13` | SetPageSize (6-byte, B1) | `[rows u16][cols u16][copies u16]` | `14` | ignored | `packet_generator.ts:115-126` |
| `85` | PrintBitmapRow | §6.3 | none | none | `packet_generator.ts:236-245` |
| `83` | PrintBitmapRowIndexed | §6.3 | none | none | `packet_generator.ts:256-273` |
| `84` | PrintEmptyRow | `[pos u16][repeat u8]` | none | none | `packet_generator.ts:232-234` |
| `E3` | PageEnd | `01` | `E4` | bool | `packet_generator.ts:228-230` |
| `A3` | PrintStatus | `01` | `B3` | §7 | `packet_parser.ts:104-119` |
| `F3` | PrintEnd | `01` | `F4` | bool (0 means still busy) | `packet_generator.ts:220-222`, `protocol.ts:447-452` |
| `DA` | CancelPrint | `01` | `D0` | n/a | `commands.ts:10,178` (not used by B1PrintTask) |

Other commands exist but the B1 flow doesn't need them: `15` PrintQuantity (u16), `20` PrintClear, `28` PrinterReset, `58` SoundSettings, `27` SetAutoShutdownTime, `8E` LabelPositioningCalibration (on B1, values 1 and 2 feed about 15 cm of paper: `protocol.ts:454-461`), `86` PrinterCheckLine. Full enums: `commands.ts:6-161`.

### 4.1 GetInfo (0x40) keys. Response ID = 0x40 + key (`enumerations.ts:5-20`, `commands.ts:103-113`)

| key | meaning | resp | parse | B1 v5.22 real reply |
|---|---|---|---|---|
| 1 | density | 41 | u8 | n/a |
| 3 | label type | 43 | u8 (§10) (`packet_parser.ts:348-351`) | `01` |
| 7 | auto shutdown | 47 | u8 enum 1..4 | `01` |
| 8 | model id | 48 | 2 bytes means u16 BE; 1 byte means `b<<8` (`packet_parser.ts:149-158`) | `10 00` = **4096 = B1** |
| 9 | software ver | 49 | `D[0] + D[1]/100` (`packet_parser.ts:302-311`) | `05 16` = 5.22 |
| 10 | battery | 4A | §8.3 | `04` = 100% |
| 11 | serial | 4B | ≥8 bytes means ASCII; 4..7 bytes means hex of the first 4; <4 means "-1" (`packet_parser.ts:313-325`) | `"G327071185"` |
| 12 | hardware ver | 4C | same as 9 | `05 0a` = 5.10 |
| 13 | BT MAC | 4D | 6 bytes, reversed, ":"-joined (`packet_parser.ts:327-330`) | n/a |

The B1 dump is at `src/test/dumps.ts:4-30`.

## 5. Session start (what niimbluelib does on serial connect)

`serial_impl.ts:60` → `abstract_client.ts:335-353`:
1. `C1` Connect, expect `C2 [03]` (ConnectedV3). On result 3, also send `A5` and get **protocolVersion = 3** for B1 (`10 00 ... D[11..12] = 02 04` gives n=204, `dumps.ts:6-8`).
2. GetInfo 8, 11, 13, 10, 7; sound settings; Heartbeat type 3 (§8.2) (`abstract_client.ts:261-299`).
3. `1A` RFID, `59` paper info (errors ignored) (`abstract_client.ts:304-329`).
4. Heartbeat every 2000 ms (`abstract_client.ts:40,432-436`).

GET_INFO answers over USB without Connect; NiimBar skips it.

## 6. Printing one label: exact sequence (B1PrintTask)

B1 uses `B1PrintTask` (`src/print_tasks/index.ts:77`, `src/print_tasks/B1PrintTask.ts:1-43`). Each step waits for its reply before the next, except the one-way rows.

```
printInit  (B1PrintTask.ts:9-15)
  1  21 [density]                     -> 31
  2  23 [labelType]                   -> 33
  3  01 [totalPages u16, 00 00 00 00, 00] -> 02
printPage  (B1PrintTask.ts:17-30), per distinct image
  4  03 [01]                          -> 04 [01]
  5  13 [rows u16, cols u16, copies u16] -> 14
  6  row packets 83/84/85, one-way, 10 ms apart, in row order
  7  E3 [01]                          -> E4 [01]
waitForFinished  (B1PrintTask.ts:32-38, protocol.ts:154-177)
  8  every pollInterval: A3 [01] -> B3 ; stop when page == totalPages
printEnd   (AbstractPrintTask.ts:157-161, protocol.ts:447-452). Always run this, even on error (AbstractPrintTask.ts:73-88)
  9  F3 [01]                          -> F4 [01]
```

- `rows` is the image height in px (feed direction). `cols` is the width in px across the printhead, padded to a multiple of 8 (`image_encoder.ts:95-96`).
- `copies` is the quantity of this image. `totalPages` in PrintStart is the sum of all copies of all images. niimblue sets `totalPages = pagesTotal * quantity` and passes `quantity` into SetPageSize (`niimblue/src/components/PrintPreview.svelte:118,158`).
- Multi-image jobs repeat steps 4-7 per image, then poll once at the end (`AbstractPrintTask.ts:76-82`, `PrintPreview.svelte:148-161`).
- B1 behaviour of PrintStart 7-byte: with totalPages > 1, after each PageEnd the paper stops at the head and waits for the next page. After the last page it feeds out (`packet_generator.ts:203-210`).
- **B1 quirk:** do NOT use the 4-byte SetPageSize `[rows, cols]`. On B1 "first print is blank or printer prints many copies". Use the 6-byte form (`packet_generator.ts:103-113`).
- Defaults: `labelType = 1` (WithGaps), `density = 2` in the lib (`AbstractPrintTask.ts:50-61`); the B1 model default is 3 (§10). niimblue stops the heartbeat while printing and restarts it after PrintEnd (`PrintPreview.svelte:115,92,177`).

### 6.1 Byte-level example: 16×4 px label, 1 copy, density 3

Image (1 means black): row0 = 16 black, row1 = same as row0, row2 = white, row3 = one black pixel at x=3.
Encoded: cols=16, rows=4. Runs: row0 pixels ×2, row2 void ×1, row3 pixels (1 black).

```
>> 55 55 21 01 03 23 aa aa                       SetDensity 3
<< 55 55 31 ..                                   (any DATA)
>> 55 55 23 01 01 23 aa aa                       SetLabelType 1
<< 55 55 33 ..
>> 55 55 01 07 00 01 00 00 00 00 00 07 aa aa     PrintStart totalPages=1, color=0
<< 55 55 02 ..
>> 55 55 03 01 01 03 aa aa                       PageStart
<< 55 55 04 01 01 04 aa aa
>> 55 55 13 06 00 04 00 10 00 01 00 aa aa        SetPageSize rows=4 cols=16 copies=1
<< 55 55 14 ..
>> 55 55 85 08 00 00 10 00 00 02 ff ff 9f aa aa  BitmapRow pos=0 counts=[16,0,0] rep=2 data=ff ff
>> 55 55 84 03 00 02 01 84 aa aa                 EmptyRow pos=2 rep=1
>> 55 55 83 08 00 03 01 00 00 01 00 03 8b aa aa  Indexed pos=3 counts=[1,0,0] rep=1 idx=[0x0003]
>> 55 55 e3 01 01 e3 aa aa                       PageEnd
<< 55 55 e4 01 01 e4 aa aa
>> 55 55 a3 01 01 a3 aa aa                       PrintStatus (repeat until page==1)
<< 55 55 b3 LL PP PP pp ff [..] CK aa aa
>> 55 55 f3 01 01 f3 aa aa                       PrintEnd
<< 55 55 f4 01 01 f4 aa aa
```
These bytes come from a reimplementation of the lib's encoder; checksums are verified against the dump frames.

### 6.2 Image to rows (`src/utils/image_encoder.ts:80-175`)

- **Orientation:** B1 has `printDirection: "top"` (`src/printer_models.ts:177`). There is no rotation: the image's x axis runs across the printhead and the y axis is the feed direction. Row 0 is printed first. With `"left"` (other models) the image is rotated 90° clockwise, using `idx = (H-1-x)*W + y` (`image_encoder.ts:45-50`).
- **Width:** `cols = ceil(width/8)*8`. Padding bits are 0 (`:95-96,113-115`). The B1 head is **384 px = 48 bytes**. niimblue only warns when the width exceeds 384 (`PrintPreview.svelte:232-237`); its 50×30 mm B1 preset is 400×240 px (`niimblue/src/defaults.ts:33`). niimprint and NiimPrintX hard-reject width > 384 for B1 (`niimprint/__main__.py:76-89`, `NiimPrintX/cli/command.py:87-88`). **Clamp to ≤384.**
- **Pixel to bit:** any colour that is not exactly `0xFFFFFF` becomes black (bit 1) (`:117-125`). Threshold or dither to pure black and white first. Bit 1 means burn. There is **no inversion** in the wire format. niimprint's `ImageOps.invert(...).convert("1")` exists only because PIL 1-bit uses 0 for black (`niimprint/printer.py:119-123`).
- **Bit order:** MSB first. Pixel `x` goes to byte `x/8`, bit `7 - x%8` (`:122`).
- **Row runs:** a row with no black pixels is `void`, otherwise it is `pixels`. A row identical to the previous run (same type and same bytes) increments that run's `repeat` instead of starting a new run (`:131-158`). The packet's `pos` is the first row of the run.
- **Run break every 200 rows:** after processing row `r` where `r % 200 == 199` (and r>0), a `check` marker is appended (`:160-170`). This forces a new run on the next row, so a run never spans rows 199→200, 399→400, and so on. B1PrintTask doesn't enable check-line packets, so the marker sends nothing (`packet_generator.ts:353-356`). Its only effect is the run split. Replicate it to stay byte-identical, and in any case never let `repeat` exceed 255 (it's a u8).

### 6.3 Row packets

| Row kind | Packet | DATA |
|---|---|---|
| void run | `84` PrintEmptyRow | `[pos u16][repeat u8]` |
| pixels, black count ≤ 6 | `83` PrintBitmapRowIndexed | `[pos u16][c0 c1 c2][repeat u8][idx u16 BE]*` |
| pixels, black count > 6 | `85` PrintBitmapRow | `[pos u16][c0 c1 c2][repeat u8][row bytes, cols/8]` |

- Selection logic: `packet_generator.ts:324-364`. The indexed form lists the x position of each black pixel, MSB-first order, ascending, each as a u16 BE (`image_encoder.ts:181-195`). With more than 6 black pixels the indexed form must not be used: "Printer powers off if black pixel count > 6" (`packet_generator.ts:256-270`).
- Max DATA for 85 on B1 is 2+3+1+48 = 54 bytes.

### 6.4 Black-pixel count bytes `c0 c1 c2` (`src/utils/utils.ts:97-152`)

- `chunk = floor(printheadPixels/8/3)`. For B1 that's `floor(384/24) = 16` bytes, i.e. 128 px per chunk. printheadPixels comes from the model table (`AbstractPrintTask.ts:153-155`).
- **Split mode** (used when `rowBytes ≤ 3*chunk`, so always on B1 when width ≤384): `c[i]` = number of 1-bits in row bytes `[16i, 16i+16)`.
- **Total mode** (row wider than 384): `c0 = 0, c1 = total & 0xFF, c2 = total >> 8`. This is the one little-endian field.
- niimprint and NiimPrintX send `00 00 00` always and report that B1 still prints (`niimprint/printer.py:124`). The count looks unvalidated, but the lib computes it, so do the same.

## 7. Completion detection (PrintStatus)

- `A3 [01]` returns `B3`. DATA: `[page u16][pagePrintProgress u8 0-100][pageFeedProgress u8 0-100]`. If LEN == 10, skip 2 more bytes; the next byte is `error` (non-zero means failure, codes in §11) (`packet_parser.ts:104-119`, `protocol.ts:298-307`). LEN can be 4, 8 or 10; only the first 4 bytes are guaranteed.
- `page` is the number of pages finished so far. **Done when `page == totalPages`** (`protocol.ts:166-169`). Then send PrintEnd.
- PrintEnd `F4 [00]` means not finished. Some other tasks poll PrintEnd every 500 ms instead (`protocol.ts:189-210`); niimprint does that on B1 (`niimprint/printer.py:113-116`, sleeping 0.3 s after PageEnd). niimbluelib's B1 path uses the status poll.
- A `0xDB` packet at any point aborts the job: send PrintEnd and surface the error.

## 8. Heartbeat (0xDC)

The response ID tells you which layout you got. The parser that matters depends on the reply's length, not on the model (`packet_parser.ts:220-300`).
**niimbluelib on B1:** B1 reports protocol v3, so it sends **type 4** and gets `D9` (`protocol.ts:361-380`). Type 1 still works and gives `DD`.

### 8.1 Type 1 → `DD` "Advanced1" (`packet_parser.ts:220-264`)

| LEN | lid (0 = closed) | battery | paper (0 = inserted) | paperRfidOk (≠0) | notes |
|---|---|---|---|---|---|
| 10 | D[8] | D[9] | n/a | n/a | D110 |
| **13** | **D[9]** | **D[10]** | **D[11]** | **D[12]** | "b1" in the parser comment; D[0..8] unknown |
| 19 | D[15] | D[16] | D[17] | D[18] | |
| 20 | n/a | n/a | D[18] | D[19] | |

- Any other LEN throws an error.
- If battery ≤ 4, multiply it by 25 (`:259-261`).
- The lid value is inverted for model IDs `512,513,514,2304,1792,3584,5120,2560,3840,4352,272,273,274` (`:253-257`). B1 (4096) isn't in that list.
- Example 13-byte reply (B21S, `dumps.ts:338-339`): `55 55 dd 0d 1f 34 00 95 00 95 00 00 54 00 03 00 01 ad aa aa` decodes to lid closed, 75%, paper in, RFID OK.

### 8.2 Type 3 → `DE` (enum name `In_HeartbeatBasic`, but it carries printer info) (`packet_parser.ts:197-218`)

The reply is exactly 10 bytes: `[hwMaj hwMin][fwMaj fwMin][printheadWidth u16][resolutionClass u8: 2=203dpi, 3=300][printheadAlignment u8][supportsRFID u8][supportsWriteRFID u8]`.
B1 sends `05 0a 05 16 01 80 02 02 01 00`: hw 5.10, fw 5.22, **384 px**, 203 dpi, RFID yes (`dumps.ts:23-24`, `test/virtual-client.test.ts:46-53`).

### 8.3 Type 4 → `D9` "Advanced2" (`packet_parser.ts:266-300`)

Layout: `[2 unknown][battery][temp °C?][lid 0=closed][paper 0=in][paperRfidOk][ribbonRfidOk][ribbonIn 0=in]`, then optional fields in this order: `[wifiRssi u16]`, `[1 skip][lightingErr u8]`, `[voltageState u8]`. Battery ≤4 is multiplied by 25.
B1 v5.22 sends 9 bytes: `20 41 04 4d 00 00 01 00 00`, which is 100%, 77, lid closed, paper in, RFID OK (`dumps.ts:25-26`).

## 9. RFID and label size

### 9.1 RfidInfo `1A [01]` → `1B` (`packet_parser.ts:160-195`, `src/packets/data_reader.ts:43-51`)

- LEN == 1 means no tag (DATA `00`).
- Otherwise:

```
uuid      8 bytes (hex)
barcode   [len i8][ASCII]      e.g. "10262260"
serial    [len i8][ASCII]      e.g. "PZ1G221322004205"
allPaper  u16                  total labels on roll
usedPaper u16                  labels used
type      u8                   LabelType (§10)
capacity  u16   (optional, present if ≥2 bytes remain)
uuid2     8 bytes (optional)
```
- Remaining labels = `allPaper - usedPaper`. niimblue shows `used/all` as a bar (`niimblue/src/components/PrinterConnector.svelte:132-143`).
- Real B1 reply (39 bytes, `dumps.ts:27-28`): `88 1d 7e 4f d9 97 00 00 | 08 "10262260" | 10 "PZ1G221322004205" | 01 14 | 00 99 | 01`, i.e. all=276, used=153, type=1.
- niimprint parses the same layout but treats `D[0]==0` as no tag (`niimprint/printer.py:181-208`).

### 9.2 Label width and height in mm

- **The RFID reply carries no dimensions.** None of the four sources maps the barcode to a size. That needs NIIMBOT's consumables lookup, which none of these sources implements.
- The only on-device size source is `59 [01]` → `69` GetPaperInfo (`packet_parser.ts:368-403`). It is valid only when LEN == 18:
  ```
  gapPx u16, totalHeightPx u16, paperType u8, gap u16 (/10 mm), totalHeight u16 (/10 mm),
  widthPx u16, width u16 (/10 mm), direction u8, tailPx u16, tail u16 (/10 mm)
  ```
  A 4-byte reply means "invalid/unknown". Some firmwares (B21 Pro, id 785) include the gap in totalHeight (`protocol.ts:467-480`); for others, height = totalHeight.
- The B1 v5.22 dump never sends `59`, so B1 support is **unverified**. Probe it, and fall back to user-chosen presets.
- Pixel conversion for B1: 203 dpi ≈ 8 px/mm (`printer_models.ts:176`, `niimblue/src/defaults.ts:33` uses dpmm 8).

## 10. B1 model constants (`src/printer_models.ts:173-183`)

| field | value |
|---|---|
| model id (GetInfo 8) | **4096** (B1_PRO = 4097 at 300 dpi/567 px, uses a different task; B1_SE = 4098 at 203 dpi/384 px) (`:184-205`) |
| dpi | 203 (8 px/mm) |
| printheadPixels | **384** (48 bytes/row) |
| printDirection | `"top"` (no rotation) |
| paperTypes | 1 WithGaps, 2 Black (black mark), 5 Transparent |
| density | min 1, max 5, **default 3** |
| print task | `B1` (`print_tasks/index.ts:77`); single colour (pageColor 0) |
| protocol version | 3 (via `A5`) |

LabelType enum (`enumerations.ts:56-67`): 0 Invalid, 1 WithGaps, 2 Black, 3 Continuous, 4 Perforated, 5 Transparent, 6 PvcTag, 10 BlackMarkGap, 11 HeatShrinkTube.

## 11. Print error codes (`0xDB` DATA[0] or PrintStatus error) (`enumerations.ts:105-145`)

| Code | Meaning |
|---|---|
| 01 | CoverOpen |
| 02 | LackPaper |
| 03 | LowBattery |
| 04 | BatteryException |
| 05 | UserCancel |
| 06 | DataError |
| 07 | Overheat |
| 08 | PaperOutException |
| 09 | PrinterBusy |
| 0A | NoPrinterHead |
| 0B | TemperatureLow |
| 0C | PrinterHeadLoose |
| 0D | NoRibbon |
| 0E | WrongRibbon |
| 0F | UsedRibbon |
| 10 | WrongPaper |
| 11 | SetPaperFail |
| 12 | SetPrintModeFail |
| 13 | SetPrintDensityFail |
| 14 | WriteRfidFail |
| 15 | SetMarginFail |
| 16 | CommunicationException |
| 17 | Disconnect |
| 18 | CanvasParameterError |
| 19 | RotationParameterException |
| 1A | JsonParameterException |
| 1B | B3sAbnormalPaperOutput |
| 1C | ECheckPaper |
| 1D | RfidTagNotWritten |
| 1E | SetPrintDensityNoSupport |
| 1F | SetPrintModeNoSupport |
| 20 | SetPrintLabelMaterialError |
| 21 | SetPrintLabelMaterialNoSupport |
| 22 | NotSupportWrittenRfid |
| 32 | IllegalPage |
| 33 | IllegalRibbonPage |
| 34 | ReceiveDataTimeout |
| 35 | NonDedicatedRibbon |

## 12. Battery and charging

- GetInfo 10 → `4A [v]`, exactly 1 byte. If `v ≤ 4`, percent = `v*25`; otherwise `v` is already a percent (`packet_parser.ts:337-341`). B1 v5.22 returns `04` (100%). B1 Pro returns `0x28` (40%) (`dumps.ts:15-16,368-369`). B1 therefore reports a **4-step level (1..4, possibly 0)**.
- Heartbeat battery uses the same mapping (§8).
- **Charging state:** no source decodes a charging flag for B1. `voltageState` exists only in Advanced2 replies of ≥13 bytes (`packet_parser.ts:289-291`), and B1 sends 9. Treat charging as unknown, or detect it empirically (for example, diff heartbeat bytes D[0..8] of `DD` with the USB cable plugged in and unplugged).

## 13. Timeouts and pacing used by the libraries

| What | Value | Source |
|---|---|---|
| Gap before every write | 10 ms | `abstract_client.ts:39,75`; `serial_impl.ts:121` |
| Default request timeout | 1000 ms | `protocol.ts:37`, `abstract_client.ts:134` |
| Timeout per packet during printPage (steps 4-7) | 10 000 ms (`pageTimeoutMs`) | `AbstractPrintTask.ts:56`, `B1PrintTask.ts:27` |
| Status poll interval | 300 ms lib default; niimblue uses **100 ms** | `AbstractPrintTask.ts:54`; `PrintPreview.svelte:122` |
| Status request timeout | 5000 ms lib; niimblue 8000 ms; 2 tries per poll | `AbstractPrintTask.ts:55`, `B1PrintTask.ts:33`, `protocol.ts:159` |
| Heartbeat interval | 2000 ms | `abstract_client.ts:40` |
| Heartbeat timeout | 500 ms | `protocol.ts:368` |
| Disconnect after failed heartbeats | 5 in a row | `abstract_client.ts:67,371-373` |
| Overall print timeout | **none** (the poll runs until page==total or an error) | `protocol.ts:154-177` |

Add your own overall cap.

## 14. Differences in other implementations (for reference only)

- **niimprint:** density, `23 [1]`, PrintStart 1-byte `[01]`, PageStart, **SetPageSize 4-byte `[height, width]`**, all rows as `85` with zero counts and repeat 1, PageEnd, sleep 0.3 s, then poll PrintEnd until it returns 1 (`niimprint/printer.py:103-127`). It finds responses as `respcode = req + offset`: GetInfo `0x40+key`; Set* commands `+0x10` (`:148-165,245-253`). niimbluelib warns that 4-byte SetPageSize misbehaves on B1, so don't copy this flow.
- **NiimPrintX** (BLE): same, plus `15` SetQuantity u16 after SetPageSize, 10 ms between rows, retries PageEnd until it returns true, polls `A3` until `page == quantity`, then PrintEnd (`NiimPrintX/nimmy/printer.py:128-152`).
- Both cap density for B1 at 1..5 (`niimprint/printer.py:250-253`).
