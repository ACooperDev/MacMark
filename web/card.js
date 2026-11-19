// The About card: this Mac as a sigil you can knead into a strip and back.
// Drag sideways, click, Space or the buttons switch shapes; hovering a ring
// or a row (or the arrow keys) says what it is in the footer. (A port of
// Machine Mark's AboutCard.qml to a browser canvas.)
//
// Drawing has two modes. At rest each ring (or strip row) is drawn once into
// its own layer and only turned; while the shape changes, everything is
// drawn every frame (Sigil.paint). The words are drawn over both.
(function() {
"use strict"
var S = window
var MM = window.MacMark = {}

function post(name, v) { try { window.webkit.messageHandlers[name].postMessage(v) } catch (e) {} }
// WebKit keeps a page's errors to itself: hand them to the app, which logs them.
window.onerror = function(msg, src, line, col, err) {
    post("error", msg + " at " + String(src || "").split("/").pop() + ":" + line + ":" + col + (err && err.stack ? "\n" + err.stack : ""))
}

var $ = function(id) { return document.getElementById(id) }
var cv = $("cv"), ctx = cv.getContext("2d"), stageEl = $("stage")
var unit = 13
var FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif'
var F_BODY = unit + "px " + FONT, F_BOLD = "600 " + unit + "px " + FONT, F_HEAD = "700 11.5px " + FONT

// ------------------------------------------------------------ state

var machine = null, readAt = 0, pal = S.paletteFrom({})
var cur = S.RINGS.map(function() { return 1 })
var target = 1, anim = null, back = false
// Which way the knead goes: dealt from a shuffled deck, so every mode plays
// once before any plays again, and no two kneads in a row go the same way
// (the number keys keep to one; 0 for random again).
var mode = "burst", modeLock = "", modeDeck = []
var drag = null, hi = -1, say = "", sayTimer = 0
var builtAt = -1e9, building = false, buildTimer = 0
var geo = null, texts = [], textsAt = 0, valW = 0, factsKey = ""
var markCache = {}, lastLayout = null, layoutMemo = null
var pulseB = 0, pulseAt = 0
var dpr = window.devicePixelRatio || 1, W = 0, H = 0, stageX = 0, stageY = 0, stageW = 0, stageH = 0

function now() { return Date.now() }
function allAt(v) { for (var i = 0; i < cur.length; i++) if (cur[i] !== v) return false; return true }
function shape() { return S.average(cur) }
function geoKey(m) { return [m.host, m.cpu.name, m.gpu.name, m.installed, m.cpu.cores, m.apps ? m.apps.count : 0, m.upgrades].join("|") }
// Everything except the values the live reading refreshes.
function slowKey(m) {
    var c = JSON.parse(JSON.stringify(m))
    delete c.memory; delete c.uptime; delete c.now
    if (c.gpu) delete c.gpu.usage
    if (c.battery) delete c.battery.charge
    delete c.thermal
    return JSON.stringify(c)
}

function pickMode() {
    if (modeLock) return modeLock
    var deck = modeDeck.slice()
    if (deck.length === 1 && deck[0] === mode) deck = []
    if (!deck.length) {
        deck = S.modeNames()
        for (var i = deck.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1)), d = deck[i]
            deck[i] = deck[j]; deck[j] = d
        }
    }
    var top = deck.length - 1
    if (top > 0 && deck[top] === mode) { deck[top] = deck[0]; deck[0] = mode }
    var m = deck.pop()
    modeDeck = deck
    return m
}

// ------------------------------------------------------------ text measuring

var mctx = document.createElement("canvas").getContext("2d"), widths = {}
function measure(str, font) {
    var k = font + "\u0000" + str
    if (widths[k] === undefined) { mctx.font = font; widths[k] = mctx.measureText(str).width }
    return widths[k]
}
function elide(str, font, room) {
    if (room <= 0) return ""
    if (measure(str, font) <= room) return str
    var lo = 0, hiI = str.length
    while (lo < hiI) { var mid = (lo + hiI + 1) >> 1; if (measure(str.slice(0, mid) + "…", font) <= room) lo = mid; else hiI = mid - 1 }
    return str.slice(0, lo) + "…"
}

// ------------------------------------------------------------ sizes

function resize() {
    dpr = window.devicePixelRatio || 1
    W = window.innerWidth; H = window.innerHeight
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr)
    cv.style.width = W + "px"; cv.style.height = H + "px"
    var r = stageEl.getBoundingClientRect()
    stageX = r.left; stageY = r.top; stageW = r.width; stageH = r.height
    layoutMemo = null
    forgetLayers()
    sendRegions()
}
// Where the header is, and its buttons: the app moves the window by a
// press anywhere else in the header, as by a title bar.
function sendRegions() {
    var hd = document.querySelector("header").getBoundingClientRect()
    var nd = Array.prototype.map.call(document.querySelectorAll("header button"), function(b) {
        var r = b.getBoundingClientRect()
        return { x: r.left, y: r.top, w: r.width, h: r.height }
    })
    post("regions", { header: hd.bottom, noDrag: nd })
}
function layoutNow() {
    var key = [stageW, stageH, unit, valW].join()
    if (!layoutMemo || layoutMemo.key !== key) layoutMemo = { key: key, Y: S.layout(stageW, stageH, { unit: unit, valW: valW }) }
    return layoutMemo.Y
}
// The header's logo in stage coordinates, where the sigil's centre lands.
function markPos() {
    var r = $("logo").getBoundingClientRect()
    return { x: r.left + r.width / 2 - stageX, y: r.top + r.height / 2 - stageY }
}

// ------------------------------------------------------------ opening

function reset() {
    cur = S.RINGS.map(function() { return 1 })
    target = 1; anim = null; drag = null; hi = -1; say = ""
    builtAt = now(); building = true
    clearTimeout(buildTimer); buildTimer = setTimeout(function() { building = false }, 1100)
    forgetLayers()
    buttons()
}

function ringsChanged() {
    markCache = {}
    layoutMemo = null
    geo = null
    texts = []
    reset()
    lastLayout = layoutNow()
}

// A reading is taken only if it is not older than the one shown.
function take(m) {
    if (machine && m.now < machine.now) return
    readAt = now()
    machine = m
    if (S.setRingsFor(machine)) ringsChanged()
    if (restShape() >= 0) markCache = {}
    header()
    refreshTexts(now())
    $("wait").style.display = "none"
    $("copy").disabled = false
    if (!geo || geo.key !== geoKey(machine)) {
        geo = S.geometry(machine); geo.key = geoKey(machine)
        builtAt = now(); building = true
        clearTimeout(buildTimer); buildTimer = setTimeout(function() { building = false }, 1100)
        factsKey = slowKey(machine)
        forgetLayers()
        return
    }
    var key = slowKey(machine)
    // New facts can change the seeded shape too.
    if (key !== factsKey) { factsKey = key; geo = S.geometry(machine); geo.key = geoKey(machine); forgetLayers() }
}

function header() {
    var m = machine
    $("host").textContent = m.host || "Mac"
    $("model").textContent = m.model || ""
    $("os").textContent = S.osText(m)
    $("os").dataset.explain = "You're running " + S.osText(m).replace(/ \((.*)\)$/, ", build $1") + (m.kernel ? ", on the Darwin " + m.kernel + " kernel." : ".")
    var bits = []
    if (m.serial) bits.push("Serial " + m.serial)
    $("ident").textContent = bits.join(" · ")
    var ex = []
    if (m.serial) ex.push("Serial number " + m.serial)
    if (m.modelNumber) ex.push("model " + m.modelNumber + (m.modelId ? " (" + m.modelId + ")" : ""))
    if (m.firmware) ex.push("firmware " + m.firmware)
    var e = ex.join(", ")
    $("ident").dataset.explain = e ? e.charAt(0).toUpperCase() + e.slice(1) + "." : ""
    sendRegions()
}

// ------------------------------------------------------------ shapes

// A knead, once started, plays through: input that would start another is
// ignored until it has settled, and so is asking for the shape it already is.
function go(to) {
    if (anim || drag || allAt(to) || !machine || !geo) return
    target = to
    back = to === 1
    mode = pickMode()
    pulseB = 1 - shape()
    if (back && S.modeOf(mode).pulseBack) { pulse(); pulseAt = now() }
    anim = { from: cur.slice(), to: to, t0: -1 }
    // A new knead's marks and particles from scratch (back to the sigil, the
    // burst's particles stay: it goes back through their cloud), worked out
    // before its first frame; its clock starts once that is done.
    var keep = {}
    if (back) for (var k in markCache) if (k.indexOf("burst") === 0) keep[k] = markCache[k]
    markCache = keep
    lastLayout = layoutNow()
    var t = now(), st = state(t)
    st.markCache = markCache
    S.prepare(lastLayout, t, st)
    anim.t0 = now()
    buttons()
}

function step(t) {
    if (!anim) return
    if (anim.t0 < 0) anim.t0 = t
    var k = S.clamp((t - anim.t0) / (back ? S.durBack(mode) : S.durOut(mode)), 0, 1), next = cur.slice()
    for (var i = 0; i < next.length; i++) next[i] = S.lerp(anim.from[i], anim.to, k)
    cur = next
    if (k >= 1) anim = null
    // The logo pulses as the core lands in it.
    if (!back && lastLayout) {
        var b = 1 - shape(), at = S.corePulse(lastLayout, markPos(), mode)
        if (at >= 0 && (b >= at) !== (pulseB >= at) && now() - pulseAt > 500) { pulse(); pulseAt = now() }
        pulseB = b
    }
}

function pulse() {
    var box = $("logoBox")
    box.classList.add("pulse")
    setTimeout(function() { box.classList.remove("pulse") }, 110)
}

function buttons() {
    $("bSigil").classList.toggle("on", target === 1)
    $("bStrip").classList.toggle("on", target === 0)
}

// ------------------------------------------------------------ words

function refreshTexts(t) {
    if (!machine) return
    var f = S.facts(machine, Math.max(0, (t - readAt) / 1000))
    texts = S.RINGS.map(function(r) { return S.text(r.k, machine, f) })
    textsAt = t
    var widest = 0
    texts.forEach(function(tx) { widest = Math.max(widest, measure(tx.s, F_BODY)) })
    widest = Math.ceil(widest)
    if (Math.abs(widest - valW) > 2) { valW = widest; forgetLayers() }
    status()
}

function statusText() {
    if (say) return say
    if (!machine) return "Reading this Mac…"
    if (hi < 0) return ""
    return texts[hi] ? texts[hi].how : ""
}
function status() { $("status").textContent = statusText() }
function tell(text) {
    say = text; status()
    clearTimeout(sayTimer); sayTimer = setTimeout(function() { say = ""; status() }, 2500)
}

function copyAll() {
    if (!machine) return
    var f = S.facts(machine, Math.max(0, (now() - readAt) / 1000))
    var text = S.report(machine, f)
    post("copy", text)
    if (!window.webkit && navigator.clipboard) navigator.clipboard.writeText(text)
    tell("Copied everything to the clipboard.")
}

// ------------------------------------------------------------ state for drawing

function state(t) {
    return { machine: machine, facts: S.facts(machine, Math.max(0, (t - readAt) / 1000)), geo: geo, pal: pal,
             cur: cur, hi: hi, builtAt: builtAt, unit: unit, mark: markPos(), back: back, mode: mode,
             headW: { hw: measure(S.CAT_NAME.hw, F_HEAD), sw: measure(S.CAT_NAME.sw, F_HEAD), age: measure(S.CAT_NAME.age, F_HEAD) },
             wordW: wordW() }
}
// The list's names' and values' widths, for what the canvas draws in with them.
function wordW() {
    var names = [], vals = [], Y = lastLayout
    for (var i = 0; i < S.RINGS.length; i++) {
        var room = Y ? Y.infoW - unit * 9.2 - 10 : 200, tx = texts[i]
        names.push(measure(S.RINGS[i].name, hi === i ? F_BOLD : F_BODY))
        vals.push(tx ? Math.min(measure(tx.l, F_BODY), Math.max(0, room)) : 0)
    }
    return { names: names, vals: vals }
}

// ------------------------------------------------------------ rest layers

// The shape at rest: 1 sigil, 0 strip, -1 while it changes or builds in.
function restShape() { return (!anim && !building && machine && geo) ? (allAt(1) ? 1 : allAt(0) ? 0 : -1) : -1 }

// Each layer remembers what it was drawn for; one whose key no longer
// matches is drawn again (a few a frame, so no frame holds long). The
// memory and battery rings and their icons follow the live reading; the slow dials
// (uptime, updated) once a minute.
var layers = { sigil: [], strip: [], stat: [null, null] }
function forgetLayers() { layers = { sigil: [], strip: [], stat: [null, null] } }
function liveKey(k) {
    if (k === "mem") return machine && machine.memory.total ? Math.round(machine.memory.used / machine.memory.total * 400) : -1
    if (k === "up" || k === "since") return Math.floor(now() / 60000)
    if (k === "heat") return machine ? machine.thermal || "" : ""
    if (k === "batt") { var ch = machine && machine.battery && machine.battery.charge; return ch ? ch.percent * 4 + (ch.plugged ? 1 : 0) + (ch.charging ? 2 : 0) : -1 }
    return 0
}
function baseKey(Y) { return [Y.w, Y.h, dpr, unit, valW, pal.fg, pal.bg, pal.accent, pal.cat.hw, pal.cat.sw, pal.cat.age, geo ? geo.key : "", factsKey].join("|") }
function newLayer(w, h) {
    var c = document.createElement("canvas")
    c.width = Math.max(1, Math.ceil(w * dpr)); c.height = Math.max(1, Math.ceil(h * dpr))
    var x = c.getContext("2d")
    x.scale(dpr, dpr)
    return { canvas: c, ctx: x, w: w, h: h }
}
// Draw what is missing for this rest shape, for up to `budget` ms; true
// once every layer is current.
function buildLayers(rs, Y, t, budget) {
    var until = performance.now() + budget, base = baseKey(Y), st = null, done = true
    var list = rs === 1 ? layers.sigil : layers.strip
    for (var i = 0; i < S.RINGS.length; i++) {
        var key = base + "|" + liveKey(S.RINGS[i].k)
        if (list[i] && list[i].key === key) continue
        if (performance.now() > until) { done = false; continue }
        if (!st) st = state(t)
        var L
        if (rs === 1) {
            var size = Math.ceil(2 * (Y.R * S.RINGS[i].r[1] + Y.R * 0.04 + 8))
            L = newLayer(size, size)
            S.paintRingLayer(L.ctx, i, size, size, Y.R, st)
        } else {
            var pad = 6, trackW = Y.tx1 - Y.tx0
            L = newLayer(trackW + 2 * pad, Y.rh + 1)
            S.paintRowLayer(L.ctx, i, pad, trackW, Y.rh / 2, Y.rh, st)
        }
        L.key = key
        list[i] = L
    }
    list.length = S.RINGS.length
    var skey = base + "|" + liveKey("mem") + "|" + liveKey("up") + "|" + liveKey("batt") + "|" + liveKey("heat")
    var sl = layers.stat[rs]
    if (!sl || sl.key !== skey) {
        if (performance.now() > until && !done) return false
        if (!st) st = state(t)
        sl = newLayer(Y.w, Y.h)
        st.cur = S.RINGS.map(function() { return rs })
        S.paintStatic(sl.ctx, Y, st)
        sl.key = skey
        layers.stat[rs] = sl
    }
    return done
}
function drawLayers(c, rs, Y, t) {
    var st = null
    c.globalAlpha = 1
    var sl = layers.stat[rs]
    c.drawImage(sl.canvas, 0, 0, sl.w, sl.h)
    for (var i = 0; i < S.RINGS.length; i++) {
        var L = (rs === 1 ? layers.sigil : layers.strip)[i]
        if (!L) continue
        c.globalAlpha = hi < 0 || hi === i ? 1 : S.DIM_RING
        if (rs === 1) {
            if (!st) st = state(t)
            c.save()
            c.translate(Y.cx, Y.cy)
            c.rotate(S.layerAngle(i, t, st) * Math.PI / 180)
            c.drawImage(L.canvas, -L.w / 2, -L.h / 2, L.w, L.h)
            c.restore()
        } else {
            c.drawImage(L.canvas, Y.tx0 - 6, Y.rowY[i] - Y.rh / 2, L.w, L.h)
        }
    }
    c.globalAlpha = 1
}

// ------------------------------------------------------------ the frame

function roundRect(c, x, y, w, h, r) {
    c.beginPath()
    c.moveTo(x + r, y); c.lineTo(x + w - r, y); c.arcTo(x + w, y, x + w, y + r, r)
    c.lineTo(x + w, y + h - r); c.arcTo(x + w, y + h, x + w - r, y + h, r)
    c.lineTo(x + r, y + h); c.arcTo(x, y + h, x, y + h - r, r)
    c.lineTo(x, y + r); c.arcTo(x, y, x + r, y, r)
    c.closePath()
}

// The picked row, as menus mark their cursor row: it slides with its row.
function drawHi(c, Y) {
    if (hi < 0 || !machine) return
    var k = cur[hi], rowH = S.lerp(Y.rh, Y.ih, k)
    // (Full at rest, eased away while a knead runs, like the dimming.)
    var a = 1 - S.hiDim(false, shape(), 0)
    if (a < 0.01) return
    var x = S.lerp(4, Y.ix, k), y = S.lerp(Y.rowY[hi], Y.yI(S.LIST_AT[hi]), k) - rowH / 2 + 1
    var w = S.lerp(Y.w - 8, Y.infoW - 10, k), h = Math.max(0, rowH - 2)
    c.globalAlpha = a
    roundRect(c, x, y, w, h, Math.min(6, h / 2))
    c.fillStyle = pal.sel; c.fill()
    c.lineWidth = 1; c.strokeStyle = pal.selBorder; c.stroke()
    c.globalAlpha = 1
}

// One word: left edge x, centred on y; turned and scaled about its middle
// when it is being drawn into the sigil (sk).
function word(c, str, x, y, w, font, color, a, sk) {
    if (!str || a < 0.01) return
    c.globalAlpha = Math.min(1, a)
    c.font = font; c.fillStyle = color
    if (sk && (sk.rot || sk.sc !== 1)) {
        c.save()
        c.translate(x + w / 2, y)
        c.rotate(sk.rot * Math.PI / 180)
        c.scale(sk.sc, sk.sc)
        c.fillText(str, -w / 2, 0)
        c.restore()
    } else c.fillText(str, x, y)
}

function drawWords(c, Y) {
    var sh = shape(), lb = S.listB(1 - sh, back, mode), wctx = { mark: markPos(), back: back, mc: markCache, mode: mode }
    c.textBaseline = "middle"
    // Section heads.
    S.CATS.forEach(function(cat) {
        var tw = measure(S.CAT_NAME[cat], F_HEAD), p = S.headPos(Y, cat, sh)
        var sk = sh > 0.5 ? S.suckAt(Y, lb, S.suckHead(Y, cat, tw)) : null
        var a = S.hiDim(hi < 0 || S.RINGS[hi].cat === cat, sh, S.DIM_TEXT) * (sk ? sk.a : 1) * S.wordAlpha(sh, Y, "h:" + cat, wctx)
        word(c, S.CAT_NAME[cat], sk ? sk.x - tw / 2 : p[0], sk ? sk.y : p[1], tw, F_HEAD, pal.cat[cat], a, sk)
    })
    // Each ring's name and value: in the list (sigil) or along the row (strip).
    for (var i = 0; i < S.RINGS.length; i++) {
        var k = cur[i] || 0, tx = texts[i] || { s: "", l: "" }, isHi = hi === i
        var shortW = measure(tx.s, F_BODY), p = S.textPos(Y, i, k, unit, Math.min(shortW, valW))
        var room = k > 0.5 ? Y.infoW - unit * 9.2 - 10 : valW
        var dimN = S.hiDim(hi < 0 || isHi, sh, S.DIM_TEXT) * S.wordAlpha(k, Y, i, wctx, "name")
        var dimV = S.hiDim(hi < 0 || isHi, sh, S.DIM_TEXT) * S.wordAlpha(k, Y, i, wctx, "value")
        var nf = isHi ? F_BOLD : F_BODY, name = S.RINGS[i].name, nameW = measure(name, nf)
        var long = elide(tx.l, F_BODY, Math.max(0, room)), longW = measure(long, F_BODY)
        var sucked = k > 0.5
        var label = sucked ? S.suckLabel(Y, i, nameW, longW) : null, value = sucked ? S.suckValue(Y, i, nameW, longW) : null
        var skL = label ? S.suckAt(Y, lb, label) : null, skN = skL ? S.suckPart(skL, p.nameX + nameW / 2 - label.x, 0) : null
        var skW = value ? S.suckAt(Y, lb, value) : null, skV = skW ? S.suckPart(skW, p.valueX + longW / 2 - value.x, 0) : null
        word(c, name, skN ? skN.x - nameW / 2 : p.nameX, skN ? skN.y : p.y, nameW, nf, isHi ? pal.fg : pal.dim, dimN * (skL ? skL.a : 1), skL)
        if (k < 0.5) {
            var short = elide(tx.s, F_BODY, Math.max(0, room))
            word(c, short, p.valueX, p.yv, measure(short, F_BODY), F_BODY, pal.fg, dimV)
        } else {
            word(c, long, skV ? skV.x - longW / 2 : p.valueX, skV ? skV.y : p.yv, longW, F_BODY, pal.fg, dimV * (skW ? skW.a : 1), skW)
        }
    }
    c.globalAlpha = 1
}

// ------------------------------------------------------------ storage legend

// Hovering Storage (at rest) shows what fills the disk, as Storage settings
// does: a bar of the categories in their colours, then each one's size.
var legendKey = "", legendEl = $("legend")
function esc(t) { return String(t).replace(/[&<>"]/g, function(ch) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch] }) }
function legendHtml(m) {
    var d = m.disk, parts = S.diskParts(m), free = d.total - (d.used || 0)
    var h = '<div class="lg-head"><b>' + esc(d.name || "Startup disk") + '</b><span>' + esc(S.gb(free)) + " available of " + esc(S.gb(d.total)) + "</span></div>"
    h += '<div class="lg-bar">' + parts.map(function(p) {
        return '<i style="width:' + (p.frac * 100).toFixed(3) + "%;background:" + S.partColor(p.name, pal) + '"></i>'
    }).join("") + "</div>"
    h += '<div class="lg-rows">' + parts.map(function(p) {
        return '<i style="background:' + S.partColor(p.name, pal) + '"></i><span>' + esc(p.name) + (p.partial ? " *" : "") + "</span><span>" + esc(S.gb(p.bytes)) + "</span>"
    }).join("") + '<i style="background:transparent;border:1px solid var(--sep)"></i><span>Available</span><span>' + esc(S.gb(free)) + "</span></div>"
    var miss = d.parts.filter(function(p) { return p.bytes === null }).map(function(p) { return p.name })
    var notes = []
    if (miss.length) notes.push(miss.join(" and ") + " can't be measured without Full Disk Access (System Settings › Privacy & Security), so " + (miss.length > 1 ? "they're" : "it's") + " counted in System Data.")
    if (parts.some(function(p) { return p.partial })) notes.push("* Some of it couldn't be read, so part of it is in System Data.")
    if (notes.length) h += '<div class="lg-note">' + notes.map(esc).join("<br>") + "</div>"
    return h
}
function updateLegend(Y, rs) {
    var show = rs >= 0 && hi >= 0 && S.RINGS[hi] && S.RINGS[hi].k === "disk" && machine && S.diskParts(machine)
    if (!show) { if (legendKey) { legendEl.classList.remove("on"); legendKey = "" } return }
    var key = [factsKey, pal.fg, pal.bg, rs, Y.w, Y.h].join("|")
    if (key !== legendKey) {
        legendEl.innerHTML = legendHtml(machine)
        var ph = legendEl.offsetHeight, pw = legendEl.offsetWidth, x, y
        if (rs === 1) {
            // Beside the list, over the sigil's side.
            var ry = Y.yI(S.LIST_AT[hi])
            x = Y.narrow ? Y.w - pw - 8 : Y.ix - pw - 14
            y = Y.narrow ? ry - ph - 14 : ry - ph / 2
        } else {
            // Above or below its row, at the right.
            var rr = Y.rowY[hi]
            x = Y.xv - pw
            y = rr > Y.h / 2 ? rr - Y.rh / 2 - ph - 6 : rr + Y.rh / 2 + 6
        }
        legendEl.style.left = Math.round(S.clamp(x, 8, Y.w - pw - 8)) + "px"
        legendEl.style.top = Math.round(S.clamp(y, 8, Y.h - ph - 8)) + "px"
        legendEl.classList.add("on")
        legendKey = key
    }
}

var lastDraw = 0, dirty = true
function frame() {
    requestAnimationFrame(frame)
    var t = now()
    if (!machine || !geo || stageW < 100 || stageH < 100) { if (dirty) { ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height); dirty = false } return }
    var rs = restShape()
    // At rest the rings turn slowly: 30 frames a second is plenty.
    if (rs >= 0 && !dirty && t - lastDraw < 32) return
    lastDraw = t; dirty = false
    step(t)
    if (t - textsAt > 5000) refreshTexts(t)
    var Y = lastLayout = layoutNow()
    rs = restShape()
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, cv.width, cv.height)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.translate(stageX, stageY)
    // (Kept to the stage, except while kneading: the core flies into the logo.)
    var ready = rs >= 0 && buildLayers(rs, Y, t, rs >= 0 ? 10 : 0)
    if (ready) drawLayers(ctx, rs, Y, t)
    else {
        var st = state(t)
        st.markCache = markCache
        S.paint(ctx, Y, t, st)
    }
    drawHi(ctx, Y)
    drawWords(ctx, Y)
    updateLegend(Y, rs)
}

// ------------------------------------------------------------ input

function stagePoint(e) { var r = stageEl.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top } }
stageEl.addEventListener("mousedown", function(e) {
    if (e.button !== 0) return
    var p = stagePoint(e)
    if (!anim) drag = { x: p.x, y: p.y, s0: shape(), moved: false }
})
window.addEventListener("mousemove", function(e) {
    if (pinned) return
    var p = stagePoint(e)
    if (drag) {
        var dx = p.x - drag.x
        if (!drag.moved && Math.abs(dx) > 5 && Math.abs(dx) > Math.abs(p.y - drag.y)) drag.moved = true
        // A drag towards the other shape (right from the sigil, left from
        // the strip) just starts that knead.
        if (drag.moved) {
            var to = drag.s0 < 0.5 ? 1 : 0
            if (to === 1 ? dx < 0 : dx > 0) { drag = null; go(to) }
            return
        }
    }
    if (lastLayout && machine && p.x >= 0 && p.y >= 0 && p.x < stageW && p.y < stageH) {
        var h = S.hit(lastLayout, { cur: cur }, p.x, p.y)
        if (h !== hi) { hi = h; status(); dirty = true }
    } else if (!drag && hi >= 0) { hi = -1; status(); dirty = true }
})
window.addEventListener("mouseup", function() {
    var d = drag
    drag = null
    if (d && !d.moved) go(1 - target)
})
document.addEventListener("mouseleave", function() { if (!pinned && !drag && hi >= 0) { hi = -1; status(); dirty = true } })

// The row above or below the picked one, as the list and the strip show
// them (top down: the outer rings first, the reverse of the rings' own
// order), wrapping round; with none picked, the first or the last.
function nextRow(dir) {
    var rows = S.LIST.filter(function(e) { return !e.head }).map(function(e) { return e.i })
    var at = rows.indexOf(hi)
    if (at < 0) return dir > 0 ? rows[0] : rows[rows.length - 1]
    return rows[(at + dir + rows.length) % rows.length]
}
document.addEventListener("keydown", function(e) {
    var k = e.key
    if (e.metaKey && (k === "c" || k === "C")) { copyAll(); e.preventDefault(); return }
    if (e.metaKey || e.ctrlKey || e.altKey) return
    var used = true
    if (k === "Escape") post("close")
    else if (k === " " || k === "Enter") go(1 - target)
    // Left to right reads sigil → strip, like the buttons: → unrolls it.
    else if (k === "ArrowLeft" || k === "h") go(1)
    else if (k === "ArrowRight" || k === "l") go(0)
    else if (/^[0-9]$/.test(k)) {
        var names = S.modeNames(), n = +k
        if (n === 0) modeLock = ""
        else if (n <= names.length) modeLock = names[n - 1]
        else return
        tell(modeLock ? "Animation " + n + ": " + S.modeOf(modeLock).title : "Animation: at random")
    }
    // C: the next colour scheme (the app keeps the choice).
    else if (k === "c" || k === "C") post("colors", true)
    else if (k === "ArrowDown" || k === "j") { hi = nextRow(1); status(); dirty = true }
    else if (k === "ArrowUp" || k === "k") { hi = nextRow(-1); status(); dirty = true }
    else used = false
    if (used) e.preventDefault()
})

$("copy").addEventListener("click", copyAll)
$("bSigil").addEventListener("click", function() { go(1) })
$("bStrip").addEventListener("click", function() { go(0) })
;["os", "ident"].forEach(function(id) {
    $(id).addEventListener("mouseenter", function() { say = $(id).dataset.explain || ""; status() })
    $(id).addEventListener("mouseleave", function() { say = ""; status() })
})
window.addEventListener("resize", function() { resize(); dirty = true })

// ------------------------------------------------------------ from the app

MM.take = function(m) { take(m); dirty = true }
// Memory, GPU load, uptime, the battery's charge and the thermal state,
// every few seconds;
// now and then the devices too.
MM.live = function(v) {
    if (!machine || !v || !v.memory || v.now < machine.now) return
    var m = JSON.parse(JSON.stringify(machine))
    m.memory = v.memory; m.uptime = v.uptime; m.now = v.now
    if (v.gpu && v.gpu.usage !== undefined) m.gpu.usage = v.gpu.usage
    if (m.battery && v.charge) m.battery.charge = v.charge
    if (typeof v.thermal === "string") m.thermal = v.thermal
    readAt = now(); machine = m
    // A device plugged in, unplugged, connected or gone: its ring anew.
    if (Array.isArray(v.devices) && JSON.stringify(v.devices) !== JSON.stringify(m.devices)) {
        m.devices = v.devices
        if (S.setRingsFor(m)) ringsChanged()
        factsKey = slowKey(m)
        markCache = {}; forgetLayers()
    }
    refreshTexts(now())
    dirty = true
}
// What fills the disk, measured after the reading: merged into the one shown.
MM.storage = function(st) {
    if (!machine || !st || !st.parts) return
    var m = JSON.parse(JSON.stringify(machine))
    m.disk.parts = st.parts; m.disk.partsAt = st.at; delete m.disk.measuring
    machine = m
    factsKey = slowKey(m)
    geo = S.geometry(m); geo.key = geoKey(m)
    markCache = {}; forgetLayers(); legendKey = ""
    refreshTexts(now())
    dirty = true
}
MM.palette = function(o) {
    pal = S.paletteFrom(o)
    var r = document.documentElement.style
    r.setProperty("--bg", pal.bg); r.setProperty("--fg", pal.fg); r.setProperty("--accent", pal.accent)
    r.setProperty("--dim", o.dimText || pal.dim)
    if (o.sep) r.setProperty("--sep", o.sep)
    markCache = {}; forgetLayers(); dirty = true
    document.body.classList.toggle("rainbow", !!o.rainbow)
    if (o.announce && o.scheme) tell("Colours: " + o.scheme + " (" + o.schemeN + " of " + o.schemes + ")")
}
MM.go = go
// (For the app's snapshots: picked and kept, whatever the pointer does.)
var pinned = false
MM.hover = function(i) { hi = i; pinned = true; status(); dirty = true }
MM.lockMode = function(n) { if (S.MODES[n]) modeLock = n }

// Opened in a plain browser (for working on the page): a reading saved with
// `MacMark --json > web/machine.json`.
resize()
reset()
requestAnimationFrame(frame)
if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) { post("ready", true); sendRegions() }
else fetch("machine.json").then(function(r) { return r.json() }).then(MM.take).catch(function() { $("wait").textContent = "Run MacMark --json > web/machine.json to view this page in a browser." })
})()
