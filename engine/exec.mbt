// Eager execution over materialized batches: filter compacts rows, the
// final aggregate folds every batch into a single output row (no GROUP
// BY in v1; SUM without matching rows yields one NULL row, per SQL).

///|
fn filter_batches(
  batches : Array[@types.DataBatch],
  pred : PhysExpr?,
) -> Array[@types.DataBatch] {
  let out : Array[@types.DataBatch] = []
  for batch in batches {
    match pred {
      None => out.push(batch)
      Some(pe) => {
        let kept = compact(batch, eval_mask(pe, batch))
        if kept.row_count() > 0 {
          out.push(kept)
        }
      }
    }
  }
  out
}

///|
fn compact(
  batch : @types.DataBatch,
  mask : FixedArray[Bool],
) -> @types.DataBatch {
  let mut kept = 0
  for r in 0..<batch.row_count() {
    if mask[r] {
      kept += 1
    }
  }
  let columns : Array[@types.ColumnVector] = []
  for src in batch.columns() {
    let dst = @types.ColumnVector::make(src.dtype(), kept)
    let mut w = 0
    for r in 0..<batch.row_count() {
      if mask[r] {
        dst.set(w, src.get(r))
        w += 1
      }
    }
    columns.push(dst)
  }
  @types.DataBatch::new(columns, kept)
}

///|
priv enum SumAcc {
  I64(Int64, Bool) // value, has_seen_non_null
  F64(Double, Bool)
}

///|
fn aggregate(
  batches : Array[@types.DataBatch],
  specs : Array[AggSpec],
) -> @types.DataBatch raise @types.SqlError {
  let k = specs.length()
  let accs : Array[SumAcc] = []
  for i in 0..<k {
    match specs[i].out_type {
      @types.Int64 => accs.push(I64(0L, false))
      @types.Float64 => accs.push(F64(0.0, false))
      other =>
        raise @types.SqlError::Execute(
          "aggregate output type \{other.to_string()} not supported",
        )
    }
  }
  for batch in batches {
    for r in 0..<batch.row_count() {
      for i in 0..<k {
        match eval_scalar(specs[i].input, batch, r) {
          @types.Null => () // SUM ignores NULL inputs
          @types.Int32(v) =>
            match accs[i] {
              I64(acc, _) => accs[i] = I64(acc + v.to_int64(), true)
              _ => ()
            }
          @types.Int64(v) =>
            match accs[i] {
              I64(acc, _) => accs[i] = I64(acc + v, true)
              _ => ()
            }
          @types.Float64(v) =>
            match accs[i] {
              F64(acc, _) => accs[i] = F64(acc + v, true)
              _ => ()
            }
          _ => ()
        }
      }
    }
  }
  let columns : Array[@types.ColumnVector] = []
  for i in 0..<k {
    let vec = @types.ColumnVector::make(specs[i].out_type, 1)
    match accs[i] {
      I64(v, seen) =>
        vec.set(
          0,
          if seen {
            @types.Scalar::Int64(v)
          } else {
            @types.Scalar::Null
          },
        )
      F64(v, seen) =>
        vec.set(
          0,
          if seen {
            @types.Scalar::Float64(v)
          } else {
            @types.Scalar::Null
          },
        )
    }
    columns.push(vec)
  }
  @types.DataBatch::new(columns, 1)
}
