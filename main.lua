-- ╔══════════════════════════════════════════════════════════════╗
-- ║         BigInt Fibonacci Calculator  ·  CC:Tweaked          ║
-- ║  Computes consecutive Fibonacci numbers of arbitrary size.  ║
-- ║  Saves a checkpoint on exit (Ctrl+T) and resumes from it.   ║
-- ╚══════════════════════════════════════════════════════════════╝

-- ── Configuration ──────────────────────────────────────────────────────────

local CHECKPOINT_FILE  = "fib_checkpoint"   -- saved in the computer's root
local DISPLAY_INTERVAL = 1.0               -- seconds between screen refreshes
local YIELD_EVERY      = 500               -- iterations between OS yields

-- ── BigInt Library ─────────────────────────────────────────────────────────
--
--  Numbers are stored as Lua arrays of "limbs" in base 10^9 (one billion),
--  least-significant limb first.  e.g. 1_234_567_890 → { 234567890, 1 }
--
--  Only addition is needed for Fibonacci, so that is all that is implemented.

local BASE        = 1000000000   -- 10^9
local BASE_DIGITS = 9            -- decimal digits per limb

-- Construct a BigInt from a non-negative integer or decimal string.
local function bi_new(n)
    local s
    if type(n) == "number" then
        -- Use string.format to avoid scientific notation on large literals.
        s = string.format("%.0f", n)
    else
        s = tostring(n)
    end
    -- Strip leading zeros and whitespace.
    s = s:match("^%s*0*(%d*)%s*$") or "0"
    if s == "" then s = "0" end

    local limbs = {}
    while #s > 0 do
        local lo    = math.max(1, #s - BASE_DIGITS + 1)
        local chunk = s:sub(lo)           -- up to BASE_DIGITS digits from right
        s           = s:sub(1, lo - 1)   -- remainder
        limbs[#limbs + 1] = tonumber(chunk)
    end
    return limbs
end

-- Convert a BigInt to its decimal string representation.
local function bi_str(a)
    if #a == 0 then return "0" end
    local parts = { tostring(a[#a]) }   -- most-significant limb (no padding)
    for i = #a - 1, 1, -1 do
        local s = tostring(a[i])
        -- Pad with leading zeros so every non-top limb is exactly BASE_DIGITS wide.
        parts[#parts + 1] = string.rep("0", BASE_DIGITS - #s) .. s
    end
    return table.concat(parts)
end

-- Add two BigInts and return the result.  Both inputs are unchanged.
local function bi_add(a, b)
    local result = {}
    local carry  = 0
    local len    = math.max(#a, #b)

    for i = 1, len do
        local s = (a[i] or 0) + (b[i] or 0) + carry
        -- Integer division / modulo without the % operator to stay fast.
        if s >= BASE then
            carry    = 1
            result[i] = s - BASE
        else
            carry    = 0
            result[i] = s
        end
    end

    if carry > 0 then
        result[len + 1] = carry
    end

    return result
end

-- Return the number of decimal digits in a BigInt.
local function bi_digit_count(a)
    if #a == 0 then return 1 end
    -- All limbs except the top are exactly BASE_DIGITS digits wide.
    return (#a - 1) * BASE_DIGITS + #tostring(a[#a])
end

-- ── Checkpoint I/O ─────────────────────────────────────────────────────────

-- Write the two-value Fibonacci state (prev, curr, index n) to disk.
local function save_checkpoint(prev, curr, n)
    local f = fs.open(CHECKPOINT_FILE, "w")
    if not f then
        printError("Could not open checkpoint file for writing.")
        return false
    end
    f.writeLine(tostring(n))
    f.writeLine(bi_str(prev))
    f.writeLine(bi_str(curr))
    f.close()
    return true
end

-- Read a previously saved checkpoint.
-- Returns (prev, curr, n) on success, or seed values if none exists.
local function load_checkpoint()
    if not fs.exists(CHECKPOINT_FILE) then
        return bi_new(0), bi_new(1), 1
    end

    local f = fs.open(CHECKPOINT_FILE, "r")
    if not f then return bi_new(0), bi_new(1), 1 end

    local n_str    = f.readLine()
    local prev_str = f.readLine()
    local curr_str = f.readLine()
    f.close()

    if not (n_str and prev_str and curr_str) then
        return bi_new(0), bi_new(1), 1
    end

    local n = tonumber(n_str)
    if not n then return bi_new(0), bi_new(1), 1 end

    return bi_new(prev_str), bi_new(curr_str), n
end

-- ── Terminal Display ────────────────────────────────────────────────────────

local W = term.getSize()

-- Draw a labelled row, truncating the value to fit the terminal width.
local function draw_row(label, value, colour)
    local prefix = label .. ": "
    local space  = W - #prefix
    local v      = tostring(value)
    if #v > space then
        -- Show the trailing digits (most interesting for large numbers).
        v = "…" .. v:sub(-(space - 1))
    end
    term.setTextColour(colour or colours.white)
    print(prefix .. v)
end

-- Full screen refresh showing the current computation state.
local function redraw(n, curr, rate, elapsed_s)
    term.clear()
    term.setCursorPos(1, 1)

    term.setTextColour(colours.yellow)
    print(("═"):rep(W))
    term.setCursorPos(math.floor((W - 26) / 2) + 1, 1)
    term.write("  BigInt Fibonacci · CC:Tweaked  ")
    term.setCursorPos(1, 2)
    print(("═"):rep(W))
    term.setTextColour(colours.white)

    draw_row("  Index  ", n,                         colours.cyan)
    draw_row("  Digits ", bi_digit_count(curr),      colours.cyan)
    draw_row("  Rate   ", string.format("%.1f iter/s", rate), colours.cyan)
    draw_row("  Uptime ", string.format("%ds", math.floor(elapsed_s)), colours.cyan)

    term.setTextColour(colours.yellow)
    print(("─"):rep(W))
    term.setTextColour(colours.white)
    draw_row("  F(n)   ", bi_str(curr),              colours.lightBlue)

    term.setTextColour(colours.yellow)
    print(("─"):rep(W))
    term.setTextColour(colours.red)
    print("  Press Ctrl+T to stop and save checkpoint.")
    term.setTextColour(colours.white)
end

-- ── Main ───────────────────────────────────────────────────────────────────

-- Banner shown at startup before entering the compute loop.
local function startup_message(resumed, n, digits)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColour(colours.yellow)
    print("BigInt Fibonacci Calculator")
    print(("─"):rep(W))
    term.setTextColour(colours.white)
    if resumed then
        print(string.format("Resuming from checkpoint at F(%d).", n))
        print(string.format("Current value has %d digit(s).", digits))
    else
        print("No checkpoint found.  Starting from F(1) = 1.")
    end
    print("")
    term.setTextColour(colours.lightGrey)
    print("Computation will begin shortly…")
    term.setTextColour(colours.white)
    os.sleep(1.5)
end

-- Load state.
local prev, curr, n = load_checkpoint()
local resumed        = fs.exists(CHECKPOINT_FILE)

startup_message(resumed, n, bi_digit_count(curr))

-- Timing bookkeeping.
local start_time   = os.clock()
local last_draw    = start_time - DISPLAY_INTERVAL   -- draw immediately
local rate_time    = start_time
local rate_iters   = 0
local rate         = 0.0

-- Main computation loop.  pcall lets us catch the Terminate signal cleanly.
local terminated = false

local ok, err = pcall(function()
    local iter = 0

    while true do
        -- ── Fibonacci step ──────────────────────────────────────────
        local next_val = bi_add(prev, curr)
        prev = curr
        curr = next_val
        n    = n + 1

        iter       = iter + 1
        rate_iters = rate_iters + 1

        -- ── Periodic yield to prevent "too long without yielding" ───
        if iter % YIELD_EVERY == 0 then
            os.sleep(0)   -- suspends for one game tick, then resumes
        end

        -- ── Periodic display refresh ────────────────────────────────
        local now = os.clock()
        if now - last_draw >= DISPLAY_INTERVAL then
            local elapsed = now - rate_time
            if elapsed > 0 then
                rate       = rate_iters / elapsed
                rate_iters = 0
                rate_time  = now
            end
            redraw(n, curr, rate, now - start_time)
            last_draw = now
        end
    end
end)

-- Determine whether we stopped due to Ctrl+T or an unexpected error.
if err then
    local s = tostring(err)
    if s:find("Terminated") then
        terminated = true
    end
end

-- ── Shutdown / Checkpoint Save ─────────────────────────────────────────────

term.clear()
term.setCursorPos(1, 1)
term.setTextColour(colours.yellow)
print("Saving checkpoint…")
term.setTextColour(colours.white)

local saved = save_checkpoint(prev, curr, n)

if saved then
    term.setTextColour(colours.lime)
    print(string.format("Saved F(%d) — %d digit(s).", n, bi_digit_count(curr)))
    print("Run this script again to resume.")
else
    term.setTextColour(colours.red)
    print("WARNING: checkpoint could not be saved!")
end

term.setTextColour(colours.white)
print("")

-- Re-raise unexpected errors so the user can see them.
if not terminated and err then
    error(err, 0)
end
