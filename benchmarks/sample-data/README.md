# Sample data for CSV and JSON

The same records written as CSV and as JSON, in three sizes. Use it to try a
parser or writer, to test one format against the other, or to check how fast
an engine is. Everything is synthetic. `gen.raku` seeds its own random
generator, so every run on every engine writes the same bytes. The names,
places and numbers are made up and contain nobody's data.

| name | records | `.csv` bytes | `.json` bytes | in git |
|---|---:|---:|---:|---|
| `small` | 100 | 18,319 | 35,282 | yes |
| `medium` | 10,000 | 1,885,731 | 3,593,004 | yes |
| `large` | 100,000 | 19,193,695 | 36,269,917 | no: generate it |

`tiny.json` is different: it is a single 49-byte JSON document, used for
timing one call. See [Timing JSON::Native](#timing-jsonnative).

`large` is the size where speed shows. It is left out of git because 55 MB
would go into every clone forever. Generating it takes about 9 seconds on
Raku++ and about a minute and a half on Rakudo. Both engines write the same
bytes, so either will do:

```sh
cd benchmarks/sample-data
rakupp gen.raku                    # small, medium and large
rakupp gen.raku 1000000 huge       # any other size: huge.csv and huge.json
```

## Timing JSON::Native

`bench-json.raku` parses one JSON file and writes it back with whichever
module `-M` loaded, and prints the best of N runs (the default is 3). A small
file is parsed and written enough times in each run to make a megabyte, and
the time of one call is printed. That is what `tiny.json` is for: a 49-byte
document, written by hand, that shows what one call costs rather than how
fast a parser reads. The performance tables in
[JSON::Native's README](../../JSON-Native/README.md#performance) come from
this script:

```sh
cd JSON-Native
rakupp -Ilib -MJSON::Native ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/large.json
raku   -Ilib -MJSON::Fast   ../benchmarks/sample-data/bench-json.raku ../benchmarks/sample-data/tiny.json 5
```

## What is in a record

CSV has one header line and these sixteen columns:

`id,name,email,city,country,street,zip,lat,lon,amount,ratio,active,manager_id,tags,note,created`

JSON is an array with one object per line. The object holds the same values,
with the address nested:

```json
{"id":1,"name":"Mateo Kierkegaard","email":"user1@example.com","address":{"street":"18 Main Street","zip":"66857","city":"København","country":"Denmark","geo":[53.280060,-126.012491]},"amount":80625.38,"ratio":0.462455,"active":false,"manager_id":1,"tags":[],"note":"plain note 1","created":"2016-08-17T05:50:51Z","meta":{}}
```

The data includes the cases parsers get wrong:

- **Non-ASCII.** The names, cities and streets are in Latin with diacritics,
  Cyrillic, CJK and Turkish. The `note` of every 17th record has an emoji.
- **Quoting.** Every 7th `note` contains quotes and a comma
  (`said "hi", then left`). In CSV that means doubled quotes. A `tags` field
  with more than one tag is quoted for its commas.
- **Line breaks inside a field.** Every 11th `note` spans two lines. In CSV
  the field is quoted; in JSON it is `\n`.
- **Backslash and TAB.** Every 13th `note` holds a Windows path and a TAB.
- **Empty and null values.** Every 19th `note` is empty. Every 4th
  `manager_id` is `null` in JSON and an empty field in CSV. `tags` can be an
  empty array, and `meta` is always `{}`.
- **Numbers.** `amount` is a decimal with two places, and every 10th amount or
  so is negative. Every 5th `ratio` has an exponent (`3.7e-12`); the others are
  plain decimals.
- **`\u` escapes.** In JSON, every 23rd record writes all of its non-ASCII
  text as `\u` escapes, with emoji as surrogate pairs. Every other record
  writes non-ASCII text as UTF-8.

The decoded values match between the formats: `tags` joined with commas
matches the CSV field, and `geo` matches `lat` and `lon`. In the CSV file
`amount`, `ratio`, `lat` and `lon` are text and in JSON they are numbers, so
compare them as numbers. Both files use LF line endings and end with a
newline. Neither has a byte order mark.

`gen.raku` writes both formats by hand, without a CSV or JSON module. A
module under test never produced its own input.
