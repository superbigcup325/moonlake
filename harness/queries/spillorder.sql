SELECT l_orderkey, l_partkey, l_extendedprice, l_shipdate FROM lineitem ORDER BY l_extendedprice DESC, l_shipdate, l_orderkey LIMIT 40
