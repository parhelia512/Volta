//T compiles:yes
//T retval:42
// Local/global variables in structs.
module test_005;

struct Test
{
	int val;
	local int localVal;
}

int main()
{
	Test.localVal = 42;
	return Test.localVal;
}
