package com.example;

public class Foo {
    public void bar(int x) {
        Object o = null;
        o.toString(); // NP_GUARANTEED_DEREF (priority 1)
    }
}
