#pragma once
namespace tbb {
template <class T> class blocked_range {
    T begin_, end_;
public:
    blocked_range(T begin, T end) : begin_(begin), end_(end) {}
    T begin() const { return begin_; }
    T end() const { return end_; }
};
}
