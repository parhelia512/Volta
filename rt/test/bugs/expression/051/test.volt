//T default:no
//T macro:expect-failure
//T has-passed:no
module test;

class Foo {}
class Bar {}

fn main() i32
{
	f := new Foo();
	arr: Bar[];
	arr ~= f;

	return 0;
}
