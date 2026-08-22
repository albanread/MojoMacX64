//===----------------------------------------------------------------------===//
// VEGA-FORK: AirTraits registration.
//===----------------------------------------------------------------------===//

#include "Target/Air/AirTraits.h"

namespace M::KGEN {

const AirTraits &AirTraits::get() {
  static const AirTraits traits;
  return traits;
}

namespace {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetTraits<AirTraits> registerAirTraits;
#pragma GCC diagnostic pop
} // namespace

} // namespace M::KGEN
