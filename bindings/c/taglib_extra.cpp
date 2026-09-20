// Custom C helpers that are not present in TagLib's official C binding.
// Built together with tag_c.cpp into the shared libtag_c (.so/.dll).
// These are the reasons this fork exists: the taiko branch carries
// this file, the prebuilt config headers (gen/) and CI
// (build.zig + .github/workflows/libtag_c.yml) producing the release
// binaries for the taiko project.

#include "audioproperties.h"
#include "tag_c.h"

extern "C" int
taglib_audioproperties_length_ms(const TagLib_AudioProperties *ap) {
  return reinterpret_cast<const TagLib::AudioProperties *>(ap)
      ->lengthInMilliseconds();
}
