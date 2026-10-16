select k, count(*), count(v), sum(v) from t group by k order by k
