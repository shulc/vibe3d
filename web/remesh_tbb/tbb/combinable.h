#pragma once
#include <utility>
namespace tbb {
template <class T> class combinable {
    T value_;
public:
    template <class Factory> explicit combinable(Factory factory) : value_(factory()) {}
    T& local() { return value_; }
    template <class Body> void combine_each(Body body) const { body(value_); }
};
}
