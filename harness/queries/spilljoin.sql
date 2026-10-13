SELECT l_orderkey, o_orderstatus, l_extendedprice
FROM lineitem JOIN orders ON l_orderkey = o_orderkey
WHERE l_orderkey <= 100
ORDER BY l_orderkey, l_extendedprice
LIMIT 50
