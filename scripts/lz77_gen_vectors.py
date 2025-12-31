from typing import List, Tuple
import math

# Token format: (distance, length, literal_byte)
Token = Tuple[int, int, int]

def compress(data: bytes, window_size: int = 16, max_length: int = 15) -> List[Token]:
    """
    Very simple LZ77-style compressor that matches RTL token format:
      - no match -> (0,0,lit)
      - match    -> (dist,len,next_lit)
    """
    tokens: List[Token] = []
    i = 0
    n = len(data)

    while i < n:
        best_len = 0
        best_dist = 0

        start = max(0, i - window_size)
        for j in range(start, i):
            dist = i - j
            if dist <= 0 or dist > window_size:
                continue

            match_len = 0
            while (
                i + match_len < n and
                j + match_len < i and
                match_len < max_length and
                data[j + match_len] == data[i + match_len]
            ):
                match_len += 1

            # Need at least one byte AFTER match for literal
            if match_len > best_len and (i + match_len) < n:
                best_len = match_len
                best_dist = dist

        if best_len > 0:
            literal = data[i + best_len]
            tokens.append((best_dist, best_len, literal))
            i += best_len + 1
        else:
            tokens.append((0, 0, data[i]))
            i += 1

    return tokens


def decompress_stream(tokens: List[Token], window_size: int = 16) -> bytes:
    """
    Golden model of RTL behavior:
    - Output is the full reconstructed stream (NOT truncated)
    - History window is truncated to window_size for future backrefs
    """
    out_full: List[int] = []
    hist: List[int] = []  # sliding window (last window_size bytes)

    for distance, length, literal in tokens:
        if length == 0:
            out_full.append(literal)
            hist.append(literal)
        else:
            if distance == 0:
                raise ValueError("Invalid token: distance=0 with length>0")
            if distance > len(hist):
                raise ValueError(f"Invalid back-reference: dist={distance}, hist_len={len(hist)}")

            start = len(hist) - distance

            # copy bytes (overlap allowed)
            for k in range(length):
                b = hist[start + k]  # hist grows, so overlap works naturally
                out_full.append(b)
                hist.append(b)
                if len(hist) > window_size:
                    hist = hist[-window_size:]

            # then literal
            out_full.append(literal)
            hist.append(literal)

        if len(hist) > window_size:
            hist = hist[-window_size:]

    return bytes(out_full)


def write_mem_files(tokens: List[Token],
                    expected: bytes,
                    dist_width: int = 4,
                    len_width: int = 4,
                    token_w: int = 16,
                    out_dir: str = ".") -> None:
    """
    Emit:
      tokens.mem   : token words, hex
      expected.mem : bytes, hex
      meta.mem     : NUM_TOKENS and EXP_LEN as 32-bit hex (2 lines)
    Token packing must match RTL: {dist,len,lit} with lit in [7:0].
    """
    hex_token_digits = (token_w + 3) // 4

    def pack_token_word(dist: int, length: int, lit: int) -> int:
        if dist >= (1 << dist_width):
            raise ValueError(f"dist too wide: {dist}")
        if length >= (1 << len_width):
            raise ValueError(f"len too wide: {length}")
        if lit < 0 or lit > 255:
            raise ValueError(f"lit invalid: {lit}")

        word = (dist << (len_width + 8)) | (length << 8) | lit
        # mask to token_w
        word &= (1 << token_w) - 1
        return word

    # tokens.mem
    with open(f"{out_dir}/tokens.mem", "w") as f:
        for d, l, lit in tokens:
            w = pack_token_word(d, l, lit)
            f.write(f"{w:0{hex_token_digits}X}\n")

    # expected.mem
    with open(f"{out_dir}/expected.mem", "w") as f:
        for b in expected:
            f.write(f"{b:02X}\n")

    # meta.mem (32-bit)
    with open(f"{out_dir}/meta.mem", "w") as f:
        f.write(f"{len(tokens):08X}\n")
        f.write(f"{len(expected):08X}\n")


if __name__ == "__main__":
    # Change this to any test string/bytes you want
    input_data = b"1010ABABX"

    DIST_WIDTH = 4
    LEN_WIDTH  = 4
    TOKEN_W    = DIST_WIDTH + LEN_WIDTH + 8
    WINDOW     = 16
    MAX_LEN    = 15

    tokens = compress(input_data, window_size=WINDOW, max_length=MAX_LEN)
    reconstructed = decompress_stream(tokens, window_size=WINDOW)

    assert reconstructed == input_data, "Python golden model mismatch (this should never happen here)"

    write_mem_files(tokens, reconstructed,
                    dist_width=DIST_WIDTH,
                    len_width=LEN_WIDTH,
                    token_w=TOKEN_W,
                    out_dir=".")

    print("Generated: tokens.mem, expected.mem, meta.mem")
    print("NUM_TOKENS =", len(tokens))
    print("EXP_LEN    =", len(reconstructed))
