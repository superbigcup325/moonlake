SELECT grp, sum(v) AS s1, count(s) AS c FROM multigroup GROUP BY grp ORDER BY grp
