#pragma once
#include "blocked_range.h"
namespace tbb {
template <class Range, class Body>
void parallel_for(const Range& range, const Body& body) { body(range); }
}
