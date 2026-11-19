(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Reveal elements as they scroll into view.
  var revealer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        entry.target.classList.add("in");
        revealer.unobserve(entry.target);
      }
    });
  }, { threshold: 0, rootMargin: "0px 0px -8% 0px" });
  document.querySelectorAll(".reveal").forEach(function (el) { revealer.observe(el); });

  // Frosted nav once the page scrolls.
  var nav = document.getElementById("nav");
  var ticking = false;
  function onScroll() {
    ticking = false;
    nav.classList.toggle("scrolled", window.scrollY > 20);
  }
  window.addEventListener("scroll", function () {
    if (!ticking) { ticking = true; requestAnimationFrame(onScroll); }
  }, { passive: true });
  onScroll();

  // Run a callback the first time an element becomes visible.
  function whenVisible(el, callback) {
    if (!el) return;
    var io = new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting) { io.disconnect(); callback(); }
    }, { threshold: 0.3 });
    io.observe(el);
  }

  function formatTokens(value) {
    return value >= 1000 ? (value / 1000).toFixed(1) + "K" : String(Math.round(value));
  }

  // Pillar 3: a live task card.
  var telemetry = document.querySelector("[data-telemetry]");
  whenVisible(telemetry, function () {
    var tokens = telemetry.querySelector("[data-count-to]");
    var cpu = telemetry.querySelector("[data-cpu]");
    var cpuLabel = telemetry.querySelector("[data-cpu-label]");
    var clock = telemetry.querySelector("[data-clock]");
    var activity = telemetry.querySelector("[data-activity]");
    var steps = [
      "Testing rateLimit.test.ts: 429 after limit, headers",
      "Editing src/middleware/rateLimit.ts",
      "Running the API integration suite",
      "Reviewing the diff before Review",
    ];
    var target = Number(tokens.getAttribute("data-count-to"));
    var start = performance.now();
    var duration = reduced ? 0 : 2200;
    (function count(now) {
      var t = duration ? Math.min(1, (now - start) / duration) : 1;
      var eased = 1 - Math.pow(1 - t, 3);
      tokens.textContent = formatTokens(target * eased);
      if (t < 1) requestAnimationFrame(count);
    })(start);

    var level = 38;
    var seconds = 22;
    var step = 0;
    var total = target;
    function tick() {
      level = Math.max(8, Math.min(96, level + (Math.random() - 0.45) * 26));
      cpu.style.width = level.toFixed(0) + "%";
      cpu.style.backgroundPosition = (-(level / 100) * 200).toFixed(0) + "px 0";
      cpuLabel.textContent = level.toFixed(0) + "%";
      cpuLabel.style.color = level > 75 ? "var(--red)" : level > 50 ? "var(--orange)" : "var(--green)";
      seconds += 1;
      clock.textContent = Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
    }
    tick();
    if (reduced) return;
    setInterval(tick, 1100);
    setInterval(function () {
      total += 120 + Math.random() * 600;
      tokens.textContent = formatTokens(total);
    }, 2600);
    setInterval(function () {
      step = (step + 1) % steps.length;
      activity.style.opacity = 0;
      setTimeout(function () { activity.textContent = steps[step]; activity.style.opacity = 1; }, 300);
    }, 3200);
  });

  // Pillar 2: light up one plugin placement at a time.
  var placements = document.querySelectorAll(".placements span");
  whenVisible(document.querySelector(".placements"), function () {
    if (!placements.length) return;
    var i = 0;
    placements[0].classList.add("lit");
    if (reduced) return;
    setInterval(function () {
      placements[i].classList.remove("lit");
      i = (i + 1) % placements.length;
      placements[i].classList.add("lit");
    }, 1400);
  });

  // Copy the install command.
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    var label = button.querySelector("span");
    button.addEventListener("click", function () {
      var text = document.querySelector(button.getAttribute("data-copy")).textContent.trim();
      var done = function () {
        button.classList.add("done");
        label.textContent = "Copied";
        setTimeout(function () { button.classList.remove("done"); label.textContent = "Copy"; }, 1800);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
      } else {
        fallbackCopy(text);
        done();
      }
    });
  });
  function fallbackCopy(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }

  // Click a screenshot to see it full size.
  var lightbox = document.getElementById("lightbox");
  var lightboxImage = lightbox.querySelector("img");
  document.querySelectorAll("[data-zoom]").forEach(function (shot) {
    shot.addEventListener("click", function () {
      var img = shot.querySelector("img");
      lightboxImage.src = img.src;
      lightboxImage.alt = img.alt;
      lightbox.hidden = false;
    });
  });
  function closeLightbox() { lightbox.hidden = true; }
  lightbox.addEventListener("click", closeLightbox);
  document.addEventListener("keydown", function (event) { if (event.key === "Escape") closeLightbox(); });
})();
