//T compiles:no
//T retval:42
// Test implicit conversion from const doesn't allow invalid conversions to occur.
module test_009;

void foo(short i)
{
}

int main()
{
    const(int) i;
    foo(i);
    return 42;
}
