//T macro:expect-failure
//T check:expected ')', got ';'
module test;

fn ichi(x: i32) i32
{
    return 1 + x;
}

fn ni(x: i32) i32
{
    return 2;
}

fn san() i32
{
    return 3;
}

fn main() i32
{
    ichi(ni(san());
    return 0;
}
