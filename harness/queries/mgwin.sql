SELECT grp, v, rn FROM (SELECT grp, v, row_number() OVER (PARTITION BY grp ORDER BY v DESC) AS rn FROM multigroup) WHERE rn <= 2 ORDER BY grp, v
