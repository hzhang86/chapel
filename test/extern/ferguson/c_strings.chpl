extern proc returns_c_string():c_string;
extern proc returns_c_string_in_argument(ref ret:c_string);
extern proc print_c_string(arg:c_string);
extern proc print_c_string_len(arg:c_string, len:c_int);
extern proc return_c_string_in_argument_with_length(ref ret:c_string, ref len:c_int);

proc go() {
  var str = "Hello";

  writeln("Should be Hello:");
  print_c_string(str.c_str());

  writeln("Should be returned_c_string x3");
  var gotc = returns_c_string();
  print_c_string(gotc);

  writeln(toString(gotc));

  var gots = toString(gotc);
  writeln(gots);

  writeln("Should be returned_c_string_in_argument x3");
  var argc:c_string;
  returns_c_string_in_argument(argc);

  print_c_string(argc);

  writeln(toString(argc));

  var args = toString(argc);
  writeln(args);

  writeln("Should be returned_c_string_in_argument_with_length x3");
  var arg2c:c_string;
  var len:c_int;
  return_c_string_in_argument_with_length(arg2c, len);

  print_c_string_len(arg2c, len);

  writeln(toString(arg2c, len));

  var arg2s = toString(arg2c, len);
  writeln(arg2s);
}

go();
