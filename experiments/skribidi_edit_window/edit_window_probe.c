// Isolated differential probe. It is not used by UIKit or Skribidi at runtime.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "skribidi/skb_font_collection.h"
#include "skribidi/skb_layout.h"

typedef struct {
    const skb_layout_t *layout;
    int cluster;
    int offset;
} signature_t;

typedef struct {
    const skb_layout_t *layout;
    int first_cluster, count, displacement;
} cluster_piece_t;

typedef struct {
    cluster_piece_t pieces[3];
    int cumulative[4];
    int piece_count, count;
} cluster_index_t;

typedef struct {
    const skb_layout_t *layout;
    int source_start, count;
} property_piece_t;

typedef struct {
    property_piece_t pieces[4];
    int cumulative[5];
    int piece_count, count;
} property_index_t;

static int lower_cluster(const skb_layout_t *layout, int offset);

typedef struct {
    int start, end;
    uint32_t gid;
    uint8_t direction, bidi_level;
    float x, y;
} visual_t;

typedef struct {
    visual_t *out;
    int count, capacity, begin, end, displacement, valid;
    float x_shift, advance;
} visual_capture_t;

static int accepted_short_windows = 0;
static int rejected_short_windows = 0;

static bool capture_visual_glyph(const skb_layout_render_glyph_t *glyph, void *opaque) {
    visual_capture_t *capture = opaque;
    if (glyph->text_range.end <= capture->begin ||
        glyph->text_range.start >= capture->end) return true;
    if (glyph->text_range.start < capture->begin ||
        glyph->text_range.end > capture->end || capture->count >= capture->capacity) {
        capture->valid = 0;
        return false;
    }
    capture->out[capture->count++] = (visual_t){
        glyph->text_range.start + capture->displacement,
        glyph->text_range.end + capture->displacement,
        glyph->glyph_id, glyph->direction, glyph->bidi_level,
        glyph->offset_x + capture->x_shift, glyph->offset_y,
    };
    capture->advance += glyph->advance_x;
    return true;
}

static int append_visual(visual_capture_t *capture, const skb_layout_t *layout,
                         int begin, int end, int displacement, float x_shift) {
    capture->begin = begin;
    capture->end = end;
    capture->displacement = displacement;
    capture->x_shift = x_shift;
    capture->advance = 0.f;
    return skb_layout_iterate_render_glyphs(layout, capture_visual_glyph, capture) &&
           capture->valid;
}

static int visual_equal(const skb_layout_t *old, const skb_layout_t *window,
                        const skb_layout_t *fresh, int start, int old_end,
                        int new_end, int old_length, int delta) {
    const int capacity = skb_layout_get_glyphs_count(old) +
                         skb_layout_get_glyphs_count(window) + 1;
    visual_t *candidate = malloc((size_t)capacity * sizeof(*candidate));
    visual_t *expected = malloc((size_t)(skb_layout_get_glyphs_count(fresh) + 1) *
                                sizeof(*expected));
    if (!candidate || !expected) {
        free(candidate);
        free(expected);
        return -1;
    }
    visual_capture_t a = {.out = candidate, .capacity = capacity, .valid = 1};
    visual_capture_t b = {.out = expected,
        .capacity = skb_layout_get_glyphs_count(fresh) + 1, .valid = 1};
    int intact = append_visual(&a, old, 0, start, 0, 0.f);
    const float prefix_width = a.advance;
    intact &= append_visual(&a, window, 0, new_end - start, start, prefix_width);
    const float new_window_width = a.advance;
    visual_t *unused = malloc((size_t)(skb_layout_get_glyphs_count(old) + 1) * sizeof(*unused));
    visual_capture_t measure = {.out = unused,
        .capacity = skb_layout_get_glyphs_count(old) + 1, .valid = unused != NULL};
    if (!unused) {
        free(candidate);
        free(expected);
        return -1;
    }
    intact &= append_visual(&measure, old, start, old_end, 0, 0.f);
    const float suffix_shift = new_window_width - measure.advance;
    free(unused);
    intact &= append_visual(&a, old, old_end, old_length, delta, suffix_shift);
    intact &= append_visual(&b, fresh, 0, old_length + delta, 0, 0.f);
    int equal = intact && a.count == b.count;
    for (int i = 0; i < a.count && equal; ++i) {
        const visual_t x = a.out[i], y = b.out[i];
        if (x.start != y.start || x.end != y.end || x.gid != y.gid ||
            x.direction != y.direction || x.bidi_level != y.bidi_level ||
            fabsf(x.x - y.x) > 0.05f || fabsf(x.y - y.y) > 0.05f) equal = 0;
    }
    free(candidate);
    free(expected);
    return equal;
}

static int has_rtl_run(const skb_layout_t *layout) {
    const skb_layout_run_t *runs = skb_layout_get_layout_runs(layout);
    for (int i = 0; i < skb_layout_get_layout_runs_count(layout); ++i)
        if (runs[i].bidi_level & 1) return 1;
    return 0;
}

static int has_emoji(const skb_layout_t *layout) {
    const skb_text_property_t *properties = skb_layout_get_text_properties(layout);
    for (int i = 0; i < skb_layout_get_text_count(layout); ++i)
        if (properties[i].flags & SKB_TEXT_PROP_EMOJI) return 1;
    return 0;
}

static int add_property_piece(property_index_t *index, const skb_layout_t *layout,
                              int begin, int end) {
    if (begin == end) return 1;
    if (begin < 0 || end > skb_layout_get_text_count(layout) ||
        begin > end || index->piece_count == 4) return 0;
    index->pieces[index->piece_count++] = (property_piece_t){layout, begin, end - begin};
    index->count += end - begin;
    index->cumulative[index->piece_count] = index->count;
    return 1;
}

static skb_text_property_t indexed_property(const property_index_t *index, int offset) {
    int low = 0, high = index->piece_count;
    while (low + 1 < high) {
        const int middle = (low + high) / 2;
        if (index->cumulative[middle] <= offset) low = middle;
        else high = middle;
    }
    const property_piece_t *piece = &index->pieces[low];
    return skb_layout_get_text_properties(piece->layout)
        [piece->source_start + offset - index->cumulative[low]];
}

typedef struct {
    int begin, end;
    float width;
} advance_measure_t;

static bool measure_glyph_advance(const skb_layout_render_glyph_t *glyph, void *opaque) {
    advance_measure_t *measure = opaque;
    if (glyph->text_range.start >= measure->begin &&
        glyph->text_range.end <= measure->end)
        measure->width += glyph->advance_x;
    return true;
}

static float range_advance(const skb_layout_t *layout, int begin, int end) {
    advance_measure_t measure = {.begin = begin, .end = end};
    skb_layout_iterate_render_glyphs(layout, measure_glyph_advance, &measure);
    return measure.width;
}

static int caret_equal(const skb_layout_t *old, const skb_layout_t *window,
                       const skb_layout_t *fresh, int start, int old_end,
                       int new_end, int old_length, int delta,
                       int *first_horizontal, int *first_vertical) {
    const float prefix_width = range_advance(old, 0, start);
    const float old_window_width = range_advance(old, start, old_end);
    const float new_window_width = range_advance(window, 0, new_end - start);
    const float suffix_shift = new_window_width - old_window_width;
    for (int i = 0; i <= old_length + delta; ++i) {
        for (int affinity = SKB_AFFINITY_TRAILING;
             affinity <= SKB_AFFINITY_LEADING; ++affinity) {
            const skb_text_position_t oracle_pos = {i, affinity};
            const skb_caret_info_t expected = skb_layout_get_caret_info_at(fresh, oracle_pos);
            const int use_prefix = i <= start && start > 0;
            const int use_suffix = i >= new_end && new_end < old_length + delta;
            const skb_layout_t *source = use_prefix || use_suffix ? old : window;
            const int source_offset = use_prefix ? i :
                use_suffix ? i - delta : i - start;
            const float shift = use_prefix ? 0.f :
                use_suffix ? suffix_shift : prefix_width;
            const skb_text_position_t source_pos = {source_offset, affinity};
            const skb_caret_info_t actual = skb_layout_get_caret_info_at(source, source_pos);
            if (*first_horizontal < 0 &&
                (fabsf(actual.x + shift - expected.x) > 0.05f ||
                 actual.direction != expected.direction)) *first_horizontal = i;
            if (*first_vertical < 0 &&
                (fabsf(actual.y - expected.y) > 0.02f ||
                 fabsf(actual.ascender - expected.ascender) > 0.02f ||
                 fabsf(actual.descender - expected.descender) > 0.02f ||
                 fabsf(actual.slope - expected.slope) > 0.001f)) *first_vertical = i;
        }
    }
    return *first_horizontal < 0;
}

static int text_properties_equal(const property_index_t *candidate,
                                 const skb_layout_t *fresh,
                                 int *first_mismatch) {
    const skb_text_property_t *c = skb_layout_get_text_properties(fresh);
    if (candidate->count != skb_layout_get_text_count(fresh)) return 0;
    for (int i = 0; i < candidate->count; ++i) {
        const skb_text_property_t value = indexed_property(candidate, i);
        if (value.flags != c[i].flags || value.script != c[i].script) {
            *first_mismatch = i;
            return 0;
        }
    }
    return 1;
}

static int seam_properties_match(const skb_layout_t *old, const skb_layout_t *window,
                                 int start, int edit, int deleted, int old_end, int delta) {
    const skb_text_property_t *a = skb_layout_get_text_properties(old);
    const skb_text_property_t *b = skb_layout_get_text_properties(window);
    for (int i = start; i < start + 4 && i < edit; ++i) {
        const skb_text_property_t x = a[i], y = b[i - start];
        if (x.flags != y.flags || x.script != y.script) return 0;
    }
    for (int i = old_end - 4; i < old_end - 1; ++i) {
        if (i < edit + deleted || i < start) continue;
        const skb_text_property_t x = a[i], y = b[i + delta - start];
        if (x.flags != y.flags || x.script != y.script) return 0;
    }
    return 1;
}

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
    const int window_count = skb_layout_get_clusters_count(window);
    int inspected_left = 0, inspected_right = 0;
    for (int i = lower_cluster(old, start);
         i < skb_layout_get_clusters_count(old) && oc[i].text_offset < start + 4; ++i) {
        const int off = oc[i].text_offset;
        const int left = off >= start && off < start + 4 && off < edit;
        if (!left) continue;
        const int local_offset = off - start;
        const int j = lower_cluster(window, local_offset);
        if (j == window_count || wc[j].text_offset != local_offset ||
            !same_cluster(old, i, window, j)) return 0;
        ++inspected_left;
    }
    for (int i = lower_cluster(old, old_end - 4);
         i < skb_layout_get_clusters_count(old) && oc[i].text_offset < old_end; ++i) {
        const int off = oc[i].text_offset;
        if (off < edit + deleted) continue;
        const int local_offset = off + delta - start;
        const int j = lower_cluster(window, local_offset);
        if (j == window_count || wc[j].text_offset != local_offset ||
            !same_cluster(old, i, window, j)) return 0;
        ++inspected_right;
    }
    return (start == 0 || inspected_left) && (old_end == old_length || inspected_right);
}

static int lower_cluster(const skb_layout_t *layout, int offset) {
    const skb_cluster_t *clusters = skb_layout_get_clusters(layout);
    int low = 0, high = skb_layout_get_clusters_count(layout);
    while (low < high) {
        const int middle = (low + high) / 2;
        if (clusters[middle].text_offset < offset) low = middle + 1;
        else high = middle;
    }
    return low;
}

static int add_piece(cluster_index_t *index, const skb_layout_t *layout,
                     int begin, int end, int displacement) {
    const skb_cluster_t *clusters = skb_layout_get_clusters(layout);
    const int first = lower_cluster(layout, begin);
    const int last = lower_cluster(layout, end);
    if ((first > 0 && clusters[first - 1].text_offset +
         clusters[first - 1].text_count > begin) ||
        (last > 0 && clusters[last - 1].text_offset +
         clusters[last - 1].text_count > end)) return 0;
    if (first == last) return 1;
    if (index->piece_count == 3) return 0;
    index->pieces[index->piece_count++] = (cluster_piece_t){
        layout, first, last - first, displacement,
    };
    index->count += last - first;
    index->cumulative[index->piece_count] = index->count;
    return 1;
}

static signature_t indexed_signature(const cluster_index_t *index, int position) {
    int low = 0, high = index->piece_count;
    while (low + 1 < high) {
        const int middle = (low + high) / 2;
        if (index->cumulative[middle] <= position) low = middle;
        else high = middle;
    }
    const cluster_piece_t *piece = &index->pieces[low];
    const int cluster = piece->first_cluster + position - index->cumulative[low];
    return (signature_t){piece->layout, cluster,
        skb_layout_get_clusters(piece->layout)[cluster].text_offset +
        piece->displacement};
}

static int same_signatures(const cluster_index_t *candidate,
                           const skb_layout_t *oracle, int *first_mismatch) {
    const skb_cluster_t *expected = skb_layout_get_clusters(oracle);
    const int expected_count = skb_layout_get_clusters_count(oracle);
    if (candidate->count != expected_count) {
        *first_mismatch = -2;
        return 0;
    }
    signature_t *sorted = malloc((size_t)expected_count * sizeof(*sorted));
    if (!sorted) return -1;
    for (int i = 0; i < expected_count; ++i)
        sorted[i] = (signature_t){oracle, i, expected[i].text_offset};
    qsort(sorted, (size_t)expected_count, sizeof(*sorted), signature_order);
    int equal = 1;
    for (int i = 0; i < candidate->count && equal; ++i) {
        const signature_t a = indexed_signature(candidate, i);
        const signature_t *b = &sorted[i];
        const skb_cluster_t ca = skb_layout_get_clusters(a.layout)[a.cluster];
        const skb_cluster_t cb = skb_layout_get_clusters(b->layout)[b->cluster];
        if (a.offset != b->offset || ca.text_count != cb.text_count ||
            ca.glyphs_count != cb.glyphs_count) {
            *first_mismatch = a.offset;
            equal = 0;
            break;
        }
        if (!same_cluster(a.layout, a.cluster, oracle, b->cluster)) {
            *first_mismatch = a.offset;
            equal = 0;
        }
    }
    free(sorted);
    return equal;
}

static int character_wrap_equal(const cluster_index_t *candidate,
                                const uint32_t *text, int text_count,
                                skb_temp_alloc_t *temp, const skb_layout_params_t *params) {
    const skb_attribute_t attributes[] = {
        skb_attribute_make_font_size(15.f),
        skb_attribute_make_text_wrap(SKB_WRAP_WORD_CHAR),
    };
    skb_layout_params_t wrapped_params = *params;
    wrapped_params.layout_width = 200.f;
    wrapped_params.layout_attributes = SKB_ATTRIBUTE_SET_FROM_STATIC_ARRAY(attributes);
    skb_layout_t *wrapped = skb_layout_create_utf32(temp, &wrapped_params, text,
                                                     text_count, (skb_attribute_set_t){0});
    if (!wrapped) return 0;
    const skb_layout_line_t *lines = skb_layout_get_lines(wrapped);
    const int line_count = skb_layout_get_lines_count(wrapped);
    int line = 0, row_start = 0, equal = 1;
    float used = 0.f;
    for (int i = 0; i < candidate->count && equal; ++i) {
        const signature_t sig = indexed_signature(candidate, i);
        const skb_cluster_t cluster =
            skb_layout_get_clusters(sig.layout)[sig.cluster];
        if (cluster.text_count != 1 || cluster.glyphs_count != 1 ||
            sig.offset != i) { equal = 0; break; }
        const float advance = skb_layout_get_glyphs(sig.layout)
            [cluster.glyphs_offset].advance_x;
        if (used > 0.f && used + advance > 200.001f) {
            if (line >= line_count || lines[line].text_range.start != row_start ||
                lines[line].text_range.end != i) { equal = 0; break; }
            ++line;
            row_start = i;
            used = 0.f;
        }
        used += advance;
    }
    if (equal && (line >= line_count || lines[line].text_range.start != row_start ||
                  lines[line].text_range.end != text_count || line + 1 != line_count))
        equal = 0;
    skb_layout_destroy(wrapped);
    return equal;
}

static skb_layout_t *shape(skb_temp_alloc_t *temp, const skb_layout_params_t *params,
                           const uint32_t *text, int count) {
    return skb_layout_create_utf32(temp, params, text, count, (skb_attribute_set_t){0});
}

static void align_window(const skb_layout_t *old, int *start, int *end) {
    const skb_cluster_t *clusters = skb_layout_get_clusters(old);
    const int first = lower_cluster(old, *start);
    const int last = lower_cluster(old, *end);
    if (first > 0 && clusters[first - 1].text_offset +
        clusters[first - 1].text_count > *start)
        *start = clusters[first - 1].text_offset;
    if (last > 0 && clusters[last - 1].text_offset +
        clusters[last - 1].text_count > *end)
        *end = clusters[last - 1].text_offset + clusters[last - 1].text_count;
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
    const int old_rtl = has_rtl_run(old);
    const int old_emoji = has_emoji(old);
    const int radii[] = {4, 16, 64, length};
    int complete_passed = 0, unsafe_accept = 0;
    for (int r = 0; r < 4; ++r) {
        int start = edit > radii[r] ? edit - radii[r] : 0;
        int old_end = edit + deleted + radii[r] < length ? edit + deleted + radii[r] : length;
        align_window(old, &start, &old_end);
        const int new_end = old_end + delta;
        skb_layout_t *window = shape(temp, params, new_text + start, new_end - start);
        if (!window) return 0;
        cluster_index_t candidate = {0};
        const int intact = add_piece(&candidate, old, 0, start, 0) &&
            add_piece(&candidate, window, 0, new_end - start, start) &&
            add_piece(&candidate, old, old_end, length, delta);
        property_index_t property_candidate = {0};
        int properties_intact = add_property_piece(&property_candidate, old, 0, start);
        if (new_end < new_length) {
            properties_intact &= add_property_piece(&property_candidate, window,
                                                     0, new_end - start - 1);
            // The final local codepoint has artificial end-of-input flags.
            properties_intact &= add_property_piece(&property_candidate, old,
                                                     old_end - 1, old_end);
        } else {
            properties_intact &= add_property_piece(&property_candidate, window,
                                                     0, new_end - start);
        }
        properties_intact &= add_property_piece(&property_candidate, old,
                                                 old_end, length);
        int first_mismatch = -1;
        const int guard = intact && properties_intact && !old_rtl && !has_rtl_run(window) &&
            !old_emoji && !has_emoji(window) &&
            seam_guard_matches(old, window, start, edit, deleted, old_end, delta, length) &&
            seam_properties_match(old, window, start, edit, deleted, old_end, delta);
        const int equal = intact ? same_signatures(&candidate, fresh, &first_mismatch) : 0;
        const int visual = intact ? visual_equal(old, window, fresh, start, old_end,
                                                new_end, length, delta) : 0;
        int first_property = -1;
        const int properties = properties_intact &&
            text_properties_equal(&property_candidate, fresh, &first_property);
        const int wrap = strcmp(name, "repeated-a") == 0 && intact ?
            character_wrap_equal(&candidate, new_text, new_length,
                                 temp, params) : -1;
        int first_caret = -1, first_vertical = -1;
        const int carets = caret_equal(old, window, fresh, start, old_end,
                                      new_end, length, delta, &first_caret,
                                      &first_vertical);
        if (verbose || (guard && (equal != 1 || visual != 1 || !properties || !carets)))
            printf("%-13s edit=%-5d radius=%-5d window=%-5d %s visual=%s props=%s@%d caret-x=%s@%d caret-y=%s@%d wrap=%s guard=%s first=%d\n",
                   name, edit, radii[r], new_end - start,
                   equal == 1 ? "equal" : intact ? "different" : "split-cluster",
                   visual == 1 ? "equal" : "different",
                   properties ? "equal" : "different", first_property,
                   carets ? "equal" : "different", first_caret,
                   first_vertical < 0 ? "equal" : "different", first_vertical,
                   wrap < 0 ? "n/a" : wrap ? "equal" : "different",
                   guard ? "accept" : "widen", first_mismatch);
        if (guard && (equal != 1 || visual != 1 || !properties || !carets)) unsafe_accept = 1;
        if (r < 3) {
            accepted_short_windows += guard != 0;
            rejected_short_windows += guard == 0;
        }
        if (r == 3 && equal == 1) complete_passed = 1;
        skb_layout_destroy(window);
    }
    skb_layout_destroy(fresh);
    skb_layout_destroy(old);
    free(new_text);
    free(old_text);
    return complete_passed && !unsafe_accept;
}

static int run_index_smoke(skb_temp_alloc_t *temp, const skb_layout_params_t *params) {
    const int length = 1024 * 1024, edit = length / 2;
    uint32_t *text = malloc((size_t)length * sizeof(*text));
    if (!text) return 0;
    for (int i = 0; i < length; ++i) text[i] = 'a';
    skb_layout_t *old = shape(temp, params, text, length);
    uint32_t changed[9] = {'a','a','a','a','W','a','a','a','a'};
    skb_layout_t *window = shape(temp, params, changed, 9);
    if (!old || !window) return 0;
    cluster_index_t index = {0};
    property_index_t properties = {0};
    const clock_t started = clock();
    const int built = add_piece(&index, old, 0, edit - 4, 0) &&
        add_piece(&index, window, 0, 9, edit - 4) &&
        add_piece(&index, old, edit + 5, length, 0) &&
        add_property_piece(&properties, old, 0, edit - 4) &&
        add_property_piece(&properties, window, 0, 8) &&
        add_property_piece(&properties, old, edit + 4, edit + 5) &&
        add_property_piece(&properties, old, edit + 5, length);
    int valid = built && index.count == length && index.piece_count == 3 &&
                properties.count == length && properties.piece_count == 4;
    for (int i = 0; i < 100000 && valid; ++i) {
        const int offset = (int)(((uint64_t)i * 7919u) % (uint64_t)length);
        valid &= indexed_signature(&index, offset).offset == offset;
        valid &= indexed_property(&properties, offset).script ==
            skb_layout_get_text_properties(old)[offset].script;
    }
    const double ms = 1000.0 * (double)(clock() - started) / CLOCKS_PER_SEC;
    printf("1MiB index: %d cluster and %d property pieces, 100000 paired random lookups, %.3f CPU ms, %s\n",
           index.piece_count, properties.piece_count, ms, valid ? "valid" : "FAILED");
    skb_layout_destroy(window);
    skb_layout_destroy(old);
    free(text);
    return valid;
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
    const uint32_t alphabet[] = {'a','b','f','i',' ',0x0644,0x0627,0x0645,
                                  0x05e9,0x05dc,0x1f469,0x200d,0x1f4bb};
    uint32_t mixed[128];
    uint32_t state = 0x91b7e11u;
    int mixed_passed = 0, mixed_total = 0;
    for (int sample = 0; sample < 32; ++sample) {
        for (int i = 0; i < 128; ++i) {
            state = state * 1664525u + 1013904223u;
            mixed[i] = alphabet[(state >> 16) % (sizeof(alphabet) / sizeof(alphabet[0]))];
        }
        const int position = 32 + sample * 2;
        mixed_total += 3;
        mixed_passed += run_case("mixed replace", mixed, 128, 1, 1, w, 1,
                                 position, 0, temp, &params);
        mixed_passed += run_case("mixed insert", mixed, 128, 1, 0, w, 1,
                                 position, 0, temp, &params);
        mixed_passed += run_case("mixed delete", mixed, 128, 1, 1, NULL, 0,
                                 position, 0, temp, &params);
    }
    printf("mixed sweep: %d/%d cases passed full-window and guard checks\n",
           mixed_passed, mixed_total);
    printf("short windows: %d accepted, %d rejected by cluster/edge/bidi gates\n",
           accepted_short_windows, rejected_short_windows);
    passed &= run_index_smoke(temp, &params);
    passed &= mixed_passed == mixed_total;
    skb_font_collection_destroy(fonts);
    skb_temp_alloc_destroy(temp);
    return passed ? 0 : 1;
}
