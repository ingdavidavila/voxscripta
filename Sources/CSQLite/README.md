# SQLite, vendored

The official amalgamation, `sqlite-amalgamation-3540100.zip` from sqlite.org,
verified against the SHA3-256 the project publishes:

    92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30

Note the algorithm. SQLite publishes SHA3-256, not SHA-256, and comparing
with the wrong one looks exactly like a tampered download.

Vendored rather than linked from the system because Apple ships a `SQLite3`
module and nothing else does: the static Linux SDK has no libsqlite3 at all,
and on Android linking the platform's copy is discouraged. One known version,
compiled from source, behaves the same on all five targets — which is the
whole point of the port.

SQLite is in the public domain.
