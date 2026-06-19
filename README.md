# Network Topology Builder 

A PostgreSQL/PostGIS function that builds a routable network topology from a line-geometry table by assigning integer `source` and `target` node IDs to every edge.

---

## Overview

`createnetworktopology.sql` defines the PL/pgSQL function `public.createnetworktopology()`. Given any PostGIS table of line geometries (roads, paths, pipelines, etc.), the function:

1. Adds `source` and `target` columns to the edge table.
2. Extracts the start-point and end-point coordinates of every edge.
3. Converts those coordinates to integer keys using a configurable precision factor, so floating-point equality comparisons are exact and reproducible.
4. Deduplicates all endpoints into a companion **vertices table** (`<edge_table>_vertices`), assigning each unique node a stable integer ID.
5. Writes the correct `source` and `target` vertex IDs back to every edge row.

The result is a fully connected graph representation ready for routing engines such as **pgRouting** and **pgrServer**.

---

## Function Signature

```sql
public.createnetworktopology(
    p_edge_table      text,                          -- target table name
    p_geom_column     text    DEFAULT 'geom',        -- geometry column
    p_edge_id_column  text    DEFAULT 'id',          -- primary key column
    p_precision       double precision DEFAULT 0.00000001  -- coordinate snap tolerance
)
RETURNS void
```

| Parameter | Description |
|-----------|-------------|
| `p_edge_table` | Name of the table containing edge geometries. |
| `p_geom_column` | Name of the PostGIS geometry column (`LINESTRING` or `MULTILINESTRING`). |
| `p_edge_id_column` | Name of the integer primary key column on the edge table. |
| `p_precision` | Coordinate snap tolerance. Coordinates are divided by this value and rounded to a `bigint` before comparison, so two endpoints that differ by less than one unit of precision are treated as the same node. The default (`1e-8`) works well for geographic coordinates (WGS 84 / EPSG:4326). |

---

## How It Works

### Step 1 — Add topology columns

```sql
ALTER TABLE <edge_table>
  ADD COLUMN IF NOT EXISTS source bigint,
  ADD COLUMN IF NOT EXISTS target bigint;
```

Both columns are reset to `NULL` at the start of every run so the function is safely re-entrant.

### Step 2 — Stage endpoints

An **unlogged** staging table (`topology_endpoints`) is created. For every edge, two rows are inserted:

| `endpoint_type` | Meaning | PostGIS function used |
|-----------------|---------|----------------------|
| `0` | Source (start of edge) | `ST_StartPoint` |
| `1` | Target (end of edge) | `ST_EndPoint` |

For `MULTILINESTRING` geometries the function uses `ST_GeometryN(..., 1)` for the first sub-geometry (source) and `ST_GeometryN(..., ST_NumGeometries(...))` for the last (target), preserving directional integrity across multi-part edges.

Coordinates are stored as integer keys:

```
x_key = round( ST_X(endpoint) / p_precision ) :: bigint
y_key = round( ST_Y(endpoint) / p_precision ) :: bigint
```

This integer-key technique avoids all floating-point equality pitfalls — two geometries that share a node but were digitised independently will hash to the same `(x_key, y_key)` pair as long as they are within the precision tolerance.

### Step 3 — Build the vertex table

```sql
CREATE UNLOGGED TABLE <edge_table>_vertices AS
  SELECT row_number() OVER () AS id, x_key, y_key
  FROM ( SELECT DISTINCT x_key, y_key FROM topology_endpoints ) q;
```

A `UNIQUE INDEX` on `(x_key, y_key)` makes subsequent join lookups fast. The sequential integer IDs assigned here are the node IDs that routing engines will use.

### Step 4 — Back-fill source / target

Two `UPDATE` statements join the edge table → staging table → vertex table to write the correct node ID into `source` (endpoint_type = 0) and `target` (endpoint_type = 1) on every edge row.

### Step 5 — Cleanup

The temporary `topology_endpoints` staging table is dropped. The vertices table is **kept** alongside the edge table for use by routing queries.

---

## Usage

```sql
-- Install the function
\i createnetworktopology.sql

-- Build topology for a roads table
SELECT public.createnetworktopology('roads');

-- Custom geometry column and precision
SELECT public.createnetworktopology(
    p_edge_table     => 'waterways',
    p_geom_column    => 'geometry',
    p_edge_id_column => 'gid',
    p_precision      => 0.0000001
);
```

After the call completes:

- `roads.source` and `roads.target` contain integer node IDs.
- `roads_vertices` contains one row per unique node with its integer ID and `(x_key, y_key)` coordinate keys.

---

## Why Source / Target Topology Matters for Routing

Graph-based routing engines do not work directly with geometries. They work with **graphs**: sets of **nodes** (vertices) connected by **edges**. Before any shortest-path or network-analysis query can run, the engine must know which node an edge starts at (`source`) and which node it ends at (`target`).

### pgRouting

pgRouting extends PostGIS with graph algorithms (Dijkstra, A\*, Bellman-Ford, Travelling Salesman, etc.). Every pgRouting algorithm requires the edge table to expose `source` and `target` integer columns that correspond to rows in an accompanying vertices table:

```sql
-- Classic Dijkstra — requires source/target on the edge table
SELECT * FROM pgr_dijkstra(
    'SELECT id, source, target, cost FROM roads',
    start_node_id,
    end_node_id
);
```

Without accurate `source` / `target` values the graph is disconnected or incorrect and the algorithm either returns no path or returns a wrong one.

pgRouting also ships its own topology builder (`pgr_createTopology`), but `createnetworktopology` offers a lightweight, dependency-free alternative that works on any PostGIS table without requiring the full pgRouting extension to be installed first.

### pgrServer

pgrServer is a routing API server built on top of pgRouting. It pre-loads the graph from the database at startup and serves route requests over HTTP. It relies entirely on the `source` and `target` columns to reconstruct the adjacency structure of the network — if those values are missing or inconsistent, the loaded graph will contain broken edges and pgrServer will return incorrect or empty routes.

### General graph libraries

Any system that builds a graph from a PostGIS table — NetworkX via psycopg2, GraphHopper with a custom importer, a custom Rust/Go router — depends on the same contract: **each edge row must carry the integer IDs of its start node and end node**. The vertices table provides the canonical node registry that ties coordinates to IDs.

### The coordinate-snapping problem

Road networks are digitised from many sources over many years. Two edges that are meant to share a node at an intersection are rarely stored with bit-identical endpoint coordinates. Without snapping, each endpoint becomes its own unique node and the graph is fragmented into thousands of disconnected sub-graphs — making routing impossible.

`createnetworktopology` solves this by converting coordinates to integer keys at a controlled precision. Any two endpoints within `p_precision` degrees (or metres, depending on the CRS) of each other are assigned the same node ID, guaranteeing a connected graph.

---

## Output Tables

### `<edge_table>` (modified in-place)

| Column | Type | Description |
|--------|------|-------------|
| `source` | `bigint` | ID of the start node (references `<edge_table>_vertices.id`). |
| `target` | `bigint` | ID of the end node (references `<edge_table>_vertices.id`). |

### `<edge_table>_vertices` (created)

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Unique node ID used as `source`/`target` on edge rows. |
| `x_key` | `bigint` | Integer-encoded X coordinate (`round(x / precision)`). |
| `y_key` | `bigint` | Integer-encoded Y coordinate (`round(y / precision)`). |

To recover the actual coordinates:

```sql
SELECT id,
       x_key * 0.00000001 AS longitude,
       y_key * 0.00000001 AS latitude
FROM roads_vertices;
```

---

## Requirements

- PostgreSQL 10+
- PostGIS 2.4+
- No pgRouting installation required to run the function itself.

---

## Performance Notes

- Staging and vertex tables are created as `UNLOGGED`, which skips WAL writes and significantly speeds up bulk inserts on large networks.
- An index on `(x_key, y_key)` is created on both the staging table and the vertices table before the back-fill updates, ensuring the joins run efficiently even on millions of edges.
- The function is re-entrant: running it twice on the same table drops and recreates the vertices table and resets `source`/`target` to `NULL` before rebuilding, so a clean topology is always produced.
