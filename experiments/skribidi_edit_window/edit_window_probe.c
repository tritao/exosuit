// Isolated differential probe. It is not used by UIKit or Skribidi at runtime.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "skribidi/skb_font_collection.h"
#include "skribidi/skb_layout.h"

typedef struct {
    const skb_layout_t *layout;
    int cluster;
    int offset;
} signature_t;

static int signature_order(const void *left, const void *right) {
    const signature_t *a = left, *b = right;
    return (a->offset > b->offset) - (a->offset < b->offset);
}

static int same_cluster(const skb_layout_t *a, int ai, const skb_layout_t *b, int bi) {
    const skb_cluster_t ca = skb_layout_get_clusters(a)[ai];
    const skb_cluster_t cb = skb_layout_get_clusters(b)[bi];
    if (ca.text_count != cb.text_count || ca.glyphs_count != cb.glyphs_count) return 0;
    const skb_glyph_t *ga = skb_layout_get_glyphs(a);
    const skb_glyph_t *gb = skb_layout_get_glyphs(b);
    for (int i = 0; i < ca.glyphs_count; ++i) {
        const skb_glyph_t x = ga[ca.glyphs_offset + i];
        const skb_glyph_t y = gb[cb.glyphs_offset + i];
        if (x.gid != y.gid || fabsf(x.advance_x - y.advance_x) > 0.001f ||
            fabsf(x.offset_y - y.offset_y) > 0.001f) return 0;
    }
    return 1;
}

static int seam_guard_matches(const skb_layout_t *old, const skb_layout_t *window,
                              int start, int edit, int deleted, int old_end,
                              int delta, int old_length) {
    const skb_cluster_t *oc = skb_layout_get_clusters(old);
    const skb_cluster_t *wc = skb_layout_get_clusters(window);
    const int old_count = skb_layout_get_clusters_count(old);
    const int window_count = skb_layout_get_clusters_count(window);
    int inspected_left = 0, inspected_right = 0;
    for (int i = 0; i < old_count; ++i) {
        const int off = oc[i].text_offset;
        const int left = off >= start && off < start + 4 && off < edit;
        const int right = off >= old_end - 4 && off >= edit + deleted && off < old_end;
        if (!left && !right) continue;
        const int local_offset = off + (right ? delta : 0) - start;
        int j = 0;
        while (j < window_count && wc[j].text_offset < local_offset) ++j;
        if (j == window_count || wc[j].text_offset != local_offset ||
            !same_cluster(old, i, window, j)) return 0;
        inspected_left += left;
        inspected_right += right;
    }
    return (start == 0 || inspected_left) && (old_end == old_length || inspected_right);
}

static int append_range(signature_t *out, int *count, const skb_layout_t *layout,
                        int begin, int end, int displacement) {
    const skb_cluster_t *clusters = skb_layout_get_clusters(layout);
    const int n = skb_layout_get_clusters_count(layout);
    for (int i = 0; i < n; ++i) {
        const int start = clusters[i].text_offset;
        const int stop = start + clusters[i].text_count;
        if (stop <= begin || start >= end) continue;
        if (start < begin || stop > end) return 0; // seam splits a shaped cluster
        out[(*count)++] = (signature_t){layout, i, start + displacement};
    }
    return 1;
}

static int same_signatures(const signature_t *candidate, int count,
                           const skb_layout_t *oracle, int *first_mismatch) {
    const skb_cluster_t *expected = skb_layout_get_clusters(oracle);
    const int expected_count = skb_layout_get_clusters_count(oracle);
    if (count != expected_count) {
        *first_mismatch = -2;
        return 0;
    }
    signature_t *sorted = malloc((size_t)expected_count * sizeof(*sorted));
    if (!sorted) return -1;
    for (int i = 0; i < expected_count; ++i)
        sorted[i] = (signature_t){oracle, i, expected[i].text_offset};
    qsort(sorted, (size_t)expected_count, sizeof(*sorted), signature_order);
    int equal = 1;
    for (int i = 0; i < count && equal; ++i) {
        const signature_t *a = &candidate[i], *b = &sorted[i];
        const skb_cluster_t ca = skb_layout_get_clusters(a->layout)[a->cluster];
        const skb_cluster_t cb = skb_layout_get_clusters(b->layout)[b->cluster];
        if (a->offset != b->offset || ca.text_count != cb.text_count ||
            ca.glyphs_count != cb.glyphs_count) {
            *first_mismatch = a->offset;
            equal = 0;
            break;
        }
        if (!same_cluster(a->layout, a->cluster, oracle, b->cluster)) {
            *first_mismatch = a->offset;
            equal = 0;
        }
    }
    free(sorted);
    return equal;
}

static skb_layout_t *shape(skb_temp_alloc_t *temp, const skb_layout_params_t *params,
                           const uint32_t *text, int count) {
    return skb_layout_create_utf32(temp, params, text, count, (skb_attribute_set_t){0});
}

static void align_window(const skb_layout_t *old, int *start, int *end) {
    const skb_cluster_t *clusters = skb_layout_get_clusters(old);
    const int count = skb_layout_get_clusters_count(old);
    for (int i = 0; i < count; ++i) {
        const int first = clusters[i].text_offset;
        const int last = first + clusters[i].text_count;
        if (first < *start && *start < last) *start = first;
        if (first < *end && *end < last) *end = last;
    }
}

static int run_case(const char *name, const uint32_t *pattern, int pattern_count,
                    int repetitions, int deleted, const uint32_t *inserted,
                    int inserted_count, int edit_position, int verbose,
                    skb_temp_alloc_t *temp, const skb_layout_params_t *params) {
    const int length = pattern_count * repetitions;
    const int edit = edit_position < 0 ? length / 2 : edit_position;
    const int delta = inserted_count - deleted;
    const int new_length = length + delta;
    uint32_t *old_text = malloc((size_t)length * sizeof(*old_text));
    uint32_t *new_text = malloc((size_t)new_length * sizeof(*new_text));
    if (!old_text || !new_text) return 0;
    for (int i = 0; i < length; ++i) old_text[i] = pattern[i % pattern_count];
    memcpy(new_text, old_text, (size_t)edit * sizeof(*new_text));
    if (inserted_count)
        memcpy(new_text + edit, inserted, (size_t)inserted_count * sizeof(*new_text));
    memcpy(new_text + edit + inserted_count, old_text + edit + deleted,
           (size_t)(length - edit - deleted) * sizeof(*new_text));
    skb_layout_t *old = shape(temp, params, old_text, length);
    skb_layout_t *fresh = shape(temp, params, new_text, new_length);
    if (!old || !fresh) return 0;
    const int radii[] = {4, 16, 64, length};
    int complete_passed = 0, unsafe_accept = 0;
    for (int r = 0; r < 4; ++r) {
        int start = edit > radii[r] ? edit - radii[r] : 0;
        int old_end = edit + deleted + radii[r] < length ? edit + deleted + radii[r] : length;
        align_window(old, &start, &old_end);
        const int new_end = old_end + delta;
        skb_layout_t *window = shape(temp, params, new_text + start, new_end - start);
        if (!window) return 0;
        const int capacity = skb_layout_get_clusters_count(old) +
            skb_layout_get_clusters_count(window);
        signature_t *candidate = malloc((size_t)capacity * sizeof(*candidate));
        if (!candidate) return 0;
        int count = 0;
        int intact = append_range(candidate, &count, old, 0, start, 0) &&
            append_range(candidate, &count, window, 0, new_end - start, start) &&
            append_range(candidate, &count, old, old_end, length, delta);
        qsort(candidate, (size_t)count, sizeof(*candidate), signature_order);
        int first_mismatch = -1;
        const int guard = intact && seam_guard_matches(old, window, start, edit,
                                                       deleted, old_end, delta, length);
        const int equal = intact ? same_signatures(candidate, count, fresh, &first_mismatch) : 0;
        if (verbose || (guard && equal != 1))
            printf("%-13s edit=%-5d radius=%-5d window=%-5d %s guard=%s first=%d\n",
                   name, edit, radii[r], new_end - start,
                   equal == 1 ? "equal" : intact ? "different" : "split-cluster",
                   guard ? "accept" : "widen", first_mismatch);
        if (guard && equal != 1) unsafe_accept = 1;
        if (r == 3 && equal == 1) complete_passed = 1;
        free(candidate);
        skb_layout_destroy(window);
    }
    skb_layout_destroy(fresh);
    skb_layout_destroy(old);
    free(new_text);
    free(old_text);
    return complete_passed && !unsafe_accept;
}

int main(void) {
    skb_temp_alloc_t *temp = skb_temp_alloc_create(1024);
    skb_font_collection_t *fonts = skb_font_collection_create();
    const char *files[] = {"IBMPlexSans-Regular.ttf", "IBMPlexSansArabic-Regular.ttf",
                           "IBMPlexSansHebrew-Regular.ttf", "NotoColorEmoji-Regular.ttf"};
    char path[1024];
    for (int i = 0; i < 4; ++i) {
        snprintf(path, sizeof(path), "%s/example/data/%s", SKRIBIDI_SOURCE, files[i]);
        if (!skb_font_collection_add_font(fonts, path,
                i == 3 ? SKB_FONT_FAMILY_EMOJI : SKB_FONT_FAMILY_DEFAULT, NULL)) return 2;
    }
    const skb_attribute_t attributes[] = {skb_attribute_make_font_size(15.f)};
    const skb_layout_params_t params = {
        .font_collection = fonts, .layout_width = 1000000.f,
        .layout_attributes = SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(attributes),
    };
    const uint32_t latin[] = {'o','f','f','i','c','e',' ','A','V',' ','f','i',' ','w','a','v','e',' '};
    const uint32_t arabic[] = {0x0644,0x0627,0x0645,0x0020,0x0633,0x0644,0x0627,0x0645};
    const uint32_t hebrew[] = {'a','b',' ',0x05e9,0x05dc,0x05d5,0x05dd,' ', 'c','d',' '};
    const uint32_t emoji[] = {0x1f469,0x200d,0x1f4bb,' ',0x1f468,0x200d,0x1f4bb,' '};
    const uint32_t repeated[] = {'a'};
    const uint32_t w[] = {'W'};
    const uint32_t arabic_edit[] = {0x0628};
    const uint32_t hebrew_edit[] = {0x05d1};
    const uint32_t emoji_edit[] = {0x1f469};
    int passed = 1;
    passed &= run_case("repeated-a", repeated, 1, 4096, 1, w, 1, -1, 1, temp, &params);
    passed &= run_case("Latin", latin, 18, 128, 1, w, 1, -1, 1, temp, &params);
    passed &= run_case("Arabic", arabic, 8, 128, 1, arabic_edit, 1, -1, 1, temp, &params);
    passed &= run_case("Hebrew/LTR", hebrew, 11, 128, 1, hebrew_edit, 1, -1, 1, temp, &params);
    passed &= run_case("emoji-ZWJ", emoji, 8, 128, 1, emoji_edit, 1, -1, 1, temp, &params);
    passed &= run_case("Latin insert", latin, 18, 128, 0, w, 1, -1, 1, temp, &params);
    passed &= run_case("Latin delete", latin, 18, 128, 1, NULL, 0, -1, 1, temp, &params);
    passed &= run_case("Arabic insert", arabic, 8, 128, 0, arabic_edit, 1, -1, 1, temp, &params);
    passed &= run_case("Arabic delete", arabic, 8, 128, 1, NULL, 0, -1, 1, temp, &params);
    int sweep_passed = 0, sweep_total = 0;
    for (int i = 0; i < 12; ++i) {
        const int position = 17 + i * 7;
        sweep_total += 3;
        sweep_passed += run_case("Latin sweep", latin, 18, 16, 1, w, 1,
                                 position, 0, temp, &params);
        sweep_passed += run_case("Arabic sweep", arabic, 8, 16, 1, arabic_edit, 1,
                                 position, 0, temp, &params);
        sweep_passed += run_case("emoji sweep", emoji, 8, 16, 1, emoji_edit, 1,
                                 position, 0, temp, &params);
    }
    printf("sweep: %d/%d positions passed full-window and guard checks\n",
           sweep_passed, sweep_total);
    passed &= sweep_passed == sweep_total;
    skb_font_collection_destroy(fonts);
    skb_temp_alloc_destroy(temp);
    return passed ? 0 : 1;
}
