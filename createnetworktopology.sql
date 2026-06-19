CREATE OR REPLACE FUNCTION public.createnetworktopology(
    p_edge_table      text,
    p_geom_column     text DEFAULT 'geom',
    p_edge_id_column  text DEFAULT 'id',
    p_precision       double precision DEFAULT 0.00000001
)
RETURNS void
LANGUAGE plpgsql
AS
$$
DECLARE
    v_vertex_table text;
BEGIN

    v_vertex_table := p_edge_table || '_vertices';

    ------------------------------------------------------------------
    -- source / target columns
    ------------------------------------------------------------------

    EXECUTE format(
        'ALTER TABLE %I
           ADD COLUMN IF NOT EXISTS source bigint,
           ADD COLUMN IF NOT EXISTS target bigint',
        p_edge_table
    );

    EXECUTE format(
        'UPDATE %I
            SET source = NULL,
                target = NULL',
        p_edge_table
    );

    ------------------------------------------------------------------
    -- endpoint staging table
    ------------------------------------------------------------------

    DROP TABLE IF EXISTS topology_endpoints;

    CREATE UNLOGGED TABLE topology_endpoints
    (
        edge_id       bigint,
        endpoint_type smallint,
        x_key         bigint,
        y_key         bigint
    );

    ------------------------------------------------------------------
    -- SOURCE NODES
    ------------------------------------------------------------------

    EXECUTE format($SQL$

        INSERT INTO topology_endpoints
        (
            edge_id,
            endpoint_type,
            x_key,
            y_key
        )

        SELECT
            %1$I,
            0,

            round(
                ST_X(
                    CASE
                        WHEN GeometryType(%2$I) IN
                             ('LINESTRING','ST_LineString')
                        THEN
                            ST_StartPoint(%2$I)

                        ELSE
                            ST_StartPoint(
                                ST_GeometryN(%2$I,1)
                            )
                    END
                ) / %3$L
            )::bigint,

            round(
                ST_Y(
                    CASE
                        WHEN GeometryType(%2$I) IN
                             ('LINESTRING','ST_LineString')
                        THEN
                            ST_StartPoint(%2$I)

                        ELSE
                            ST_StartPoint(
                                ST_GeometryN(%2$I,1)
                            )
                    END
                ) / %3$L
            )::bigint

        FROM %4$I

    $SQL$,
        p_edge_id_column,
        p_geom_column,
        p_precision,
        p_edge_table
    );

    ------------------------------------------------------------------
    -- TARGET NODES
    ------------------------------------------------------------------

    EXECUTE format($SQL$

        INSERT INTO topology_endpoints
        (
            edge_id,
            endpoint_type,
            x_key,
            y_key
        )

        SELECT
            %1$I,
            1,

            round(
                ST_X(
                    CASE
                        WHEN GeometryType(%2$I) IN
                             ('LINESTRING','ST_LineString')
                        THEN
                            ST_EndPoint(%2$I)

                        ELSE
                            ST_EndPoint(
                                ST_GeometryN(
                                    %2$I,
                                    ST_NumGeometries(%2$I)
                                )
                            )
                    END
                ) / %3$L
            )::bigint,

            round(
                ST_Y(
                    CASE
                        WHEN GeometryType(%2$I) IN
                             ('LINESTRING','ST_LineString')
                        THEN
                            ST_EndPoint(%2$I)

                        ELSE
                            ST_EndPoint(
                                ST_GeometryN(
                                    %2$I,
                                    ST_NumGeometries(%2$I)
                                )
                            )
                    END
                ) / %3$L
            )::bigint

        FROM %4$I

    $SQL$,
        p_edge_id_column,
        p_geom_column,
        p_precision,
        p_edge_table
    );

    ------------------------------------------------------------------
    -- endpoint index
    ------------------------------------------------------------------

    CREATE INDEX topology_endpoints_xy_idx
        ON topology_endpoints(x_key,y_key);

    ------------------------------------------------------------------
    -- vertex table
    ------------------------------------------------------------------

    EXECUTE format(
        'DROP TABLE IF EXISTS %I',
        v_vertex_table
    );

    EXECUTE format(
        '
        CREATE UNLOGGED TABLE %I AS

        SELECT
            row_number() OVER() AS id,
            x_key,
            y_key

        FROM
        (
            SELECT DISTINCT
                x_key,
                y_key
            FROM topology_endpoints
        ) q
        ',
        v_vertex_table
    );

    EXECUTE format(
        '
        CREATE UNIQUE INDEX %I_xy_idx
        ON %I(x_key,y_key)
        ',
        v_vertex_table,
        v_vertex_table
    );

    ------------------------------------------------------------------
    -- SOURCE UPDATE
    ------------------------------------------------------------------

    EXECUTE format(
        '
        UPDATE %1$I e
           SET source = v.id
          FROM topology_endpoints p
          JOIN %2$I v
            ON v.x_key = p.x_key
           AND v.y_key = p.y_key
         WHERE p.endpoint_type = 0
           AND p.edge_id = e.%3$I
        ',
        p_edge_table,
        v_vertex_table,
        p_edge_id_column
    );

    ------------------------------------------------------------------
    -- TARGET UPDATE
    ------------------------------------------------------------------

    EXECUTE format(
        '
        UPDATE %1$I e
           SET target = v.id
          FROM topology_endpoints p
          JOIN %2$I v
            ON v.x_key = p.x_key
           AND v.y_key = p.y_key
         WHERE p.endpoint_type = 1
           AND p.edge_id = e.%3$I
        ',
        p_edge_table,
        v_vertex_table,
        p_edge_id_column
    );

    ------------------------------------------------------------------
    -- cleanup
    ------------------------------------------------------------------

    DROP TABLE topology_endpoints;

END;
$$;
