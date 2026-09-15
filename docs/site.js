/* Copy button. The command scrolls horizontally in its box, so selecting it by
   hand is fiddly -- which is the whole reason this is worth a script on an
   otherwise static page. Clipboard access can be refused (insecure context, or
   a browser that declines), so failure selects the text instead of silently
   doing nothing. */
document.querySelectorAll(".copy").forEach(function (button) {
  var code = button.closest(".cmd").querySelector("code");
  var timer;
  function flash(label, state) {
    clearTimeout(timer);
    button.textContent = label;
    if (state) { button.dataset.state = state; } else { delete button.dataset.state; }
    timer = setTimeout(function () {
      button.textContent = "Copy";
      delete button.dataset.state;
    }, 1800);
  }
  function selectInstead() {
    var range = document.createRange();
    range.selectNodeContents(code);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    flash("Selected", null);
  }
  button.addEventListener("click", function () {
    var text = code.textContent.trim();
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () {
        flash("Copied", "done");
      }, selectInstead);
    } else {
      selectInstead();
    }
  });
});
