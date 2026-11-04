# Data packs

Data packs add **content, never code**, to cartridges that are already compiled into the app.

* **Format:** a JSON envelope (`format: "yantrasobi.datapack"`, `schema: 1`, `id`, `cartridge`,
  `title`, `version`, optional `author`) wrapping a cartridge-specific `payload` object.
  See `lib/yantrasobi/datapacks/data_pack.dart`.
* **Validation:** the console checks the envelope (size limit 256 KB, schema, id and semver). The
  target cartridge, which must implement `DataPackConsumer`, then validates the payload. A pack for an
  unknown cartridge, or for one that accepts no packs, is rejected.
* **Delivery:** packs are stored in the key/value store (`yantrasobi.datapacks`) and handed to a
  running cartridge as `CartridgeContext.dataPacks`, which holds validated payload maps.
* **UI:** Settings > Data packs lets you paste JSON or install the bundled sample.
* **Transport:** this build installs packs from pasted text or bundled assets. A download source can
  be added later as a transport that feeds the same `DataPackRepository.install(raw)`. The validator,
  not the transport, is the security boundary, so packs from untrusted sources are safe to try.

## Consumers

| Cartridge | Payload | Where pack content appears |
|---|---|---|
| Brickfall | `{"levels": [{"name": "...", "rows": ["..........", ...]}]}`. Rows are exactly 10 characters from the legend `. 1 2 3 # * W M S L H`; up to 14 rows and 50 levels per pack. | After the 10 built-in levels, before generated levels |

Sample: `assets/datapacks/brickfall_neon_nights.json` (3 levels).
