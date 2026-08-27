<?php
/**
 * DPX Serialization-Safe URL Search & Replace
 * ===========================================
 *
 * Streams an SQL dump from STDIN (or file argument), replaces every
 * occurrence of OLD_URL with NEW_URL, and writes the patched dump to
 * STDOUT (or file argument).
 *
 * CRITICAL: Updates PHP byte-length headers for PHP-serialized strings
 * (`s:LENGTH:"VALUE";` -> `s:NEW_LENGTH:"NEW_VALUE";`).  This is
 * mandatory for Joomla/OpenCart/WordPress options that store arrays
 * inside MySQL as `serialize()` payloads (postmeta, configuration
 * strings, module settings, widgets).
 *
 * Designed to run INSIDE the DDEV web container via `ddev exec php`,
 * so it is fully portable across macOS/BSD/Linux hosts.
 *
 * Usage (host side):
 *   ddev exec php /var/www/html/.ddev/commands/host/dpx_serialize_safe_replace.php \
 *       --old='https://old.example' --new='https://new.example' \
 *       < input.sql > output.sql
 *
 * Or with explicit input/output files:
 *   ddev exec php ... --old=... --new=... --in=input.sql --out=output.sql
 *
 * Suppresses all PHP deprecation noise via CLI flags at the caller
 * level; this script does not emit any PHP warnings regardless of the
 * input it parses.
 *
 * Exit codes:
 *   0 - success
 *   1 - bad arguments
 *   2 - input file not readable
 *   3 - output file not writable
 *   4 - parse failure (regex error)
 */

declare(strict_types=1);

// @codingStandardsIgnoreStart
// Suppress deprecation noise even if caller forgot the -d flags.
@ini_set('display_errors', '0');
@ini_set('display_startup_errors', '0');
error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED & ~E_NOTICE & ~E_WARNING);
// @codingStandardsIgnoreEnd

/**
 * Parse argv into an associative array of [--key=value | --key value]
 * pairs.  Plain positional arguments are ignored (we only use flags).
 */
function dpx_parse_args(array $argv): array
{
    $out = [];
    $n   = count($argv);
    for ($i = 0; $i < $n; $i++) {
        $a = (string) $argv[$i];
        if (strpos($a, '--') !== 0) {
            continue;
        }
        $eq = strpos($a, '=');
        if ($eq !== false) {
            $key = substr($a, 2, $eq - 2);
            $val = substr($a, $eq + 1);
        } else {
            $key = substr($a, 2);
            $val = ($i + 1 < $n && strpos((string) $argv[$i + 1], '--') !== 0)
                ? (string) $argv[++$i]
                : '';
        }
        $out[$key] = $val;
    }
    return $out;
}

/**
 * PCRE for one PHP-serialized string token: s:LENGTH:"PAYLOAD";
 * PAYLOAD may contain escaped quotes (\") and other SQL escapes
 * (\\, \/, \', ...) so the matcher never consumes SQL syntax.
 */
const DPX_SERIALIZED_TOKEN_PATTERN = '/s:(\d+):"((?:[^"\\\\]|\\\\.)*)";/';

/**
 * Replace URL occurrences INSIDE `s:N:"...";` tokens and re-emit the
 * correct byte length.  Payload is measured on the UNESCAPED value
 * (what MySQL stores after import), then re-escaped with addslashes
 * so it stays valid SQL in both single- and double-quoted literals.
 */
function dpx_replace_serialized_tokens(string $line, string $old, string $new): string
{
    if ($old === '' || strpos($line, 's:') === false) {
        return $line;
    }

    $result = preg_replace_callback(
        DPX_SERIALIZED_TOKEN_PATTERN,
        static function (array $m) use ($old, $new): string {
            $unescaped = stripcslashes($m[2]);
            if (!is_string($unescaped) || strpos($unescaped, $old) === false) {
                return $m[0]; // untouched token: keep byte-for-byte
            }
            $fixed = str_replace($old, $new, $unescaped);
            return 's:' . strlen($fixed) . ':"' . addslashes($fixed) . '";';
        },
        $line
    );

    return is_string($result) ? $result : $line;
}

/**
 * Safety net: recompute the byte length of EVERY `s:N:"...";` token
 * whose declared length no longer matches the (unescaped) payload.
 * Catches serialized payloads mutated by the plain-literal pass.
 */
function dpx_fix_serialized_lengths(string $line): string
{
    if (strpos($line, 's:') === false) {
        return $line;
    }

    $result = preg_replace_callback(
        DPX_SERIALIZED_TOKEN_PATTERN,
        static function (array $m): string {
            $unescaped = stripcslashes($m[2]);
            if (!is_string($unescaped) || strlen($unescaped) === (int) $m[1]) {
                return $m[0];
            }
            return 's:' . strlen($unescaped) . ':"' . $m[2] . '";';
        },
        $line
    );

    return is_string($result) ? $result : $line;
}

/**
 * Replace all occurrences of $old with $new in a SQL dump line.
 *
 * Three-phase, serialization-safe strategy:
 *   1. Serialized tokens first: URL replaced on the unescaped payload
 *      and the `s:LENGTH:` header recomputed (byte-accurate).
 *   2. Plain occurrences throughout the dump line.  This also handles
 *      bare domains stored in serialized values and keys (for example,
 *      a `host` value), not only occurrences of the complete old URL.
 *   3. Final length audit over all serialized tokens (defense in
 *      depth in case phase 2 mutated a payload length).
 */
function dpx_replace_in_line(string $line, string $old, string $new): string
{
    if ($old === '') {
        return $line;
    }

    $oldBare = preg_replace('#^https?://#', '', rtrim($old, '/'));
    $newBare = preg_replace('#^https?://#', '', rtrim($new, '/'));
    $oldBare = is_string($oldBare) ? $oldBare : $old;
    $newBare = is_string($newBare) ? $newBare : $new;

    $line = dpx_replace_serialized_tokens($line, $old, $new);
    if ($oldBare !== $old) {
        $line = dpx_replace_serialized_tokens($line, $oldBare, $newBare);
    }

    // The helper is used for known URL/domain values.  Replacing across the
    // complete line is intentional: serialized keys and values can contain
    // either the full URL or only its bare domain.
    $line = str_replace($old, $new, $line);
    if ($oldBare !== $old) {
        $line = str_replace($oldBare, $newBare, $line);
    }

    return dpx_fix_serialized_lengths($line);
}

function dpx_main(array $argv): int
{
    // Skip script name.
    array_shift($argv);
    $args = dpx_parse_args($argv);

    $old = isset($args['old']) ? (string) $args['old'] : '';
    $new = isset($args['new']) ? (string) $args['new'] : '';
    $in  = isset($args['in'])  ? (string) $args['in']  : '';
    $out = isset($args['out']) ? (string) $args['out'] : '';

    if ($old === '' || $new === '') {
        fwrite(STDERR, "dpx_serialize_safe_replace: --old and --new are required\n");
        return 1;
    }
    if ($old === $new) {
        // No-op; still copy input to output verbatim.
        $old = '__dpx_noop__';
    }

    $inHandle  = $in  === '' ? STDIN  : @fopen($in,  'rb');
    $outHandle = $out === '' ? STDOUT : @fopen($out, 'wb');

    if ($inHandle === false) {
        fwrite(STDERR, "dpx_serialize_safe_replace: cannot open input: $in\n");
        return 2;
    }
    if ($outHandle === false) {
        fwrite(STDERR, "dpx_serialize_safe_replace: cannot open output: $out\n");
        return 3;
    }

    // Stream the dump line by line.  SQL dumps are normally <= 1 GiB;
    // streaming keeps memory flat and lets us process large imports.
    $carry = '';
    $lineNo = 0;
    while (!feof($inHandle)) {
        $chunk = fread($inHandle, 1 << 16); // 64 KiB
        if ($chunk === false) {
            break;
        }
        $buffer = $carry . $chunk;
        // Process every complete line in the buffer.  INSERT VALUES may
        // contain newlines inside string literals; we tolerate that by
        // keeping a trailing partial line in $carry and processing
        // every line individually.  byte-length recompute still works
        // because serialized strings do not span newlines in practice.
        $newlinePos = strpos($buffer, "\n");
        while ($newlinePos !== false) {
            $line = substr($buffer, 0, $newlinePos + 1);
            $buffer = (string) substr($buffer, $newlinePos + 1);
            $rewritten = dpx_replace_in_line($line, $old, $new);
            fwrite($outHandle, $rewritten);
            $lineNo++;
            $newlinePos = strpos($buffer, "\n");
        }
        $carry = $buffer;
    }
    if ($carry !== '') {
        $rewritten = dpx_replace_in_line($carry . "\n", $old, $new);
        // Strip the synthetic newline we added.
        fwrite($outHandle, rtrim($rewritten, "\n"));
        $lineNo++;
    }

    if ($in  !== '') { fclose($inHandle); }
    if ($out !== '') { fclose($outHandle); }

    // Write a tiny marker to STDERR (captured by the host caller) so
    // the Bash layer can log how many lines we processed.
    fwrite(STDERR, "dpx_serialize_safe_replace: lines=$lineNo old_len=" . strlen($old) . " new_len=" . strlen($new) . "\n");
    return 0;
}

exit(dpx_main($argv));
