import osler/parser

pub fn parse_date_basic_test() {
  assert parser.parse_date("2024-06-13") == Ok(#(2024, 6, 13))
  assert parser.parse_date("20240613") == Ok(#(2024, 6, 13))
  assert parser.parse_date("2024/6/7") == Ok(#(2024, 6, 7))
}

pub fn parse_date_no_semantic_validation_test() {
  // Unlike `osler.parse_date`, out-of-range values pass right through --
  // this module only checks the string's shape.
  assert parser.parse_date("2024-02-30") == Ok(#(2024, 2, 30))
  assert parser.parse_date("2024-13-99") == Ok(#(2024, 13, 99))
}

pub fn parse_date_invalid_shape_test() {
  assert parser.parse_date("") == Error(Nil)
  assert parser.parse_date("2024-06-13a") == Error(Nil)
  assert parser.parse_date("2046") == Error(Nil)
}

pub fn parse_time_basic_test() {
  assert parser.parse_time("13:42:11") == Ok(#(13, 42, 11, 0))
  assert parser.parse_time("13:42:11.354") == Ok(#(13, 42, 11, 354_000_000))
}

pub fn parse_time_no_semantic_validation_test() {
  assert parser.parse_time("99:99:99") == Ok(#(99, 99, 99, 0))
}

pub fn parse_offset_basic_test() {
  assert parser.parse_offset("-04:00") == Ok(-240)
  assert parser.parse_offset("Z") == Ok(0)
}

pub fn parse_offset_no_range_validation_test() {
  assert parser.parse_offset("+20:00") == Ok(1200)
}

pub fn parse_naive_datetime_basic_test() {
  assert parser.parse_naive_datetime("2024-06-13T13:42:11")
    == Ok(#(2024, 6, 13, 13, 42, 11, 0))
  assert parser.parse_naive_datetime("2024-06-13")
    == Ok(#(2024, 6, 13, 0, 0, 0, 0))
}

// The full date+time+offset parse (now `parse_ixdtf`, which also captures the
// RFC 9557 suffix) is covered in `osler_ixdtf_test`.
