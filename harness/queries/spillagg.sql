SELECT l_returnflag, count(*) AS c, sum(l_extendedprice) AS s, median(l_extendedprice) AS m
FROM lineitem
GROUP BY l_returnflag
ORDER BY l_returnflag
