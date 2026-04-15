'use strict';

hterm.defaultStorage = new lib.Storage.Memory();

window.fontSizeDetectionMethod = 'canvas';

function _postMessage(op, data) {
  window.webkit.messageHandlers.interOp.postMessage({op, data});
}

function _debugLog(message, extra) {
  var payload = {message: String(message)};
  if (extra !== undefined) {
    payload.extra = extra;
  }
  _postMessage('log', payload);
}

hterm.notify = function(params) {
  var def = (curr, fallback) => curr !== undefined ? curr : fallback;
  if (params === undefined || params === null) {
    params = {};
  }


  var title = def(params.title, window.document.title);
  if (!title)
    title = 'hterm';

  _postMessage('notify', {title, body: params.body})
}

hterm.Terminal.prototype.ringBell = function() {
  // Blink cursor on BEL character
  this.cursorNode_.style.backgroundColor = this.scrollPort_.getForegroundColor();
    
  setTimeout(() => this.restyleCursor_(), 200);
  
  _postMessage('ring-bell', null);
};

hterm.Terminal.prototype.copyStringToClipboard = function(content) {
  if (this.prefs_.get('enable-clipboard-notice')) {
    setTimeout(this.showOverlay.bind(this, hterm.notifyCopyMessage, 500), 200);
  }

  document.getSelection().removeAllRanges();
  _postMessage('copy', {content});
};

document.addEventListener('selectionchange', function() {
  _postMessage('selectionchange', term_getCurrentSelection());
});

function _sendStringToNative(string) {
  var pendingNoConvert = window.__blinkPendingNoConvertCommit;
  if (pendingNoConvert) {
    if (
      string === pendingNoConvert.original ||
      string === pendingNoConvert.replacement
    ) {
      string = pendingNoConvert.replacement;
      window.__blinkPendingNoConvertCommit = null;
    } else if (string && string !== '\r') {
      window.__blinkPendingNoConvertCommit = null;
    }
  }
  _postMessage('sendString', {string});
}

function _patchBlinkInstallKB() {
  if (
    typeof window.installKB !== 'function' ||
    window.installKB.__blinkIMEPatched
  ) {
    return;
  }

  var originalInstallKB = window.installKB;
  window.installKB = function(term, element) {
    originalInstallKB(term, element);

    var kb = window._kb;
    if (!kb || kb.__blinkIMEPatched) {
      return;
    }
    kb.__blinkIMEPatched = true;

    kb.__blinkCompositionText = '';
    kb.__blinkRawCompositionText = '';
    kb.__blinkSkipNextCompositionEnd = false;

    function blinkRawASCIIFromEvent(event) {
      if (!event || event.ctrlKey || event.altKey || event.metaKey) {
        return '';
      }

      var code = event.code || '';
      if (/^Key[A-Z]$/.test(code)) {
        var letter = code.slice(3);
        return event.shiftKey ? letter : letter.toLowerCase();
      }

      if (/^Digit[0-9]$/.test(code)) {
        return code.slice(5);
      }

      switch (code) {
        case 'Space':
          return ' ';
        case 'Minus':
          return '-';
        case 'Equal':
          return '=';
        case 'BracketLeft':
          return '[';
        case 'BracketRight':
          return ']';
        case 'Backslash':
          return '\\';
        case 'Semicolon':
          return ';';
        case 'Quote':
          return "'";
        case 'Comma':
          return ',';
        case 'Period':
          return '.';
        case 'Slash':
          return '/';
        case 'Backquote':
          return '`';
        default:
          break;
      }

      if (
        event.key &&
        event.key.length === 1 &&
        /^[\x20-\x7E]$/.test(event.key)
      ) {
        return event.key;
      }

      return '';
    }

    if (typeof kb._onIME === 'function' && kb.element) {
      var previousOnIME = kb._onIME;
      var originalOnIME = kb._onIME.bind(kb);

      kb.element.removeEventListener('compositionstart', previousOnIME);
      kb.element.removeEventListener('compositionupdate', previousOnIME);
      kb.element.removeEventListener('compositionend', previousOnIME);

      kb._onIME = function(event) {
        var eventType = event && event.type ? event.type : '';
        var data = event && event.data ? event.data : '';

        if (eventType === 'compositionend' && this.__blinkSkipNextCompositionEnd) {
          this.__blinkSkipNextCompositionEnd = false;
          this.__blinkCompositionText = '';
          this.__blinkRawCompositionText = '';
          if (
            window.webkit &&
            window.webkit.messageHandlers &&
            window.webkit.messageHandlers._kb
          ) {
            window.webkit.messageHandlers._kb.postMessage({
              op: 'ime',
              type: 'compositionend',
              data: '',
            });
          }
          if (typeof this._moveCaret === 'function') {
            this._moveCaret('');
          }
          return;
        }

        if (eventType === 'compositionstart' || eventType === 'compositionupdate') {
          this.__blinkCompositionText = data;
        } else if (eventType === 'compositionend') {
          this.__blinkCompositionText = '';
          this.__blinkRawCompositionText = '';
        }

        return originalOnIME(event);
      };

      kb.element.addEventListener('compositionstart', kb._onIME);
      kb.element.addEventListener('compositionupdate', kb._onIME);
      kb.element.addEventListener('compositionend', kb._onIME);
    }

    if (typeof kb.onKB === 'function') {
      var originalOnKB = kb.onKB.bind(kb);
      kb.onKB = function(operation, data) {
        if (
          operation === 'mods-down' &&
          this._isHKB &&
          typeof this._lang === 'string' &&
          this._lang.indexOf('ja') === 0 &&
          this.__blinkRawCompositionText
        ) {
          if (typeof this._output === 'function') {
            this._output(this.__blinkRawCompositionText);
          }
          this.__blinkSkipNextCompositionEnd = true;
          this.__blinkCompositionText = '';
          this.__blinkRawCompositionText = '';
          if (this.caret) {
            this.caret.innerHTML = '&#8288;';
          }
          return;
        }

        return originalOnKB(operation, data);
      };
    }

    if (typeof kb._onKeyDown === 'function' && kb.element) {
      var previousKeyDown = kb._onKeyDown;
      var originalKeyDown = kb._onKeyDown.bind(kb);

      kb.element.removeEventListener('keydown', previousKeyDown);
      window.removeEventListener('keydown', previousKeyDown);

      kb._onKeyDown = function(event) {
        if (
          this._isHKB &&
          typeof this._lang === 'string' &&
          this._lang.indexOf('ja') === 0 &&
          !event.ctrlKey &&
          !event.altKey &&
          !event.metaKey
        ) {
          if (event.code === 'Backspace') {
            this.__blinkRawCompositionText = this.__blinkRawCompositionText.slice(0, -1);
          } else {
            var rawChar = blinkRawASCIIFromEvent(event);
            if (rawChar) {
              this.__blinkRawCompositionText += rawChar;
            }
          }
        }

        if (
          this._isHKB &&
          typeof this._lang === 'string' &&
          this._lang.indexOf('ja') === 0 &&
          event.ctrlKey &&
          !event.altKey &&
          !event.metaKey &&
          event.code === 'Semicolon' &&
          this.__blinkRawCompositionText
        ) {
          event.preventDefault();
          event.stopPropagation();
          this._output(this.__blinkRawCompositionText);
          this.__blinkSkipNextCompositionEnd = true;
          this.__blinkCompositionText = '';
          this.__blinkRawCompositionText = '';
          if (this.caret) {
            this.caret.innerHTML = '&#8288;';
          }
          return;
        }

        if (
          this._isHKB &&
          typeof this._lang === 'string' &&
          this._lang.indexOf('ja') === 0 &&
          event.code === 'CapsLock' &&
          this.__blinkRawCompositionText
        ) {
          event.preventDefault();
          event.stopPropagation();
          this._output(this.__blinkRawCompositionText);
          this.__blinkSkipNextCompositionEnd = true;
          this.__blinkCompositionText = '';
          this.__blinkRawCompositionText = '';
          if (this.caret) {
            this.caret.innerHTML = '&#8288;';
          }
          return;
        }

        return originalKeyDown(event);
      };

      kb.element.addEventListener('keydown', kb._onKeyDown);
      window.addEventListener('keydown', kb._onKeyDown);
    }
  };

  window.installKB.__blinkIMEPatched = true;
}

_patchBlinkInstallKB();

var _blinkKanaDigraphToRomaji = {
  'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
  'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho',
  'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho',
  'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
  'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
  'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
  'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
  'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
  'じゃ': 'ja',  'じゅ': 'ju',  'じょ': 'jo',
  'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
  'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
  'ゔぁ': 'va',  'ゔぃ': 'vi',  'ゔぇ': 've', 'ゔぉ': 'vo',
  'てゃ': 'tha', 'てぃ': 'thi', 'てゅ': 'thu', 'てょ': 'tho',
  'でゃ': 'dha', 'でぃ': 'dhi', 'でゅ': 'dhu', 'でょ': 'dho',
  'とぅ': 'tu',  'どぅ': 'du',
  'ふぁ': 'fa',  'ふぃ': 'fi',  'ふぇ': 'fe', 'ふぉ': 'fo',
  'つぁ': 'tsa', 'つぃ': 'tsi', 'つぇ': 'tse', 'つぉ': 'tso',
  'しぇ': 'she', 'ちぇ': 'che', 'じぇ': 'je',
  'うぁ': 'wa',  'うぃ': 'wi',  'うぇ': 'we', 'うぉ': 'wo'
};

var _blinkKanaToRomaji = {
  'あ': 'a',  'い': 'i',  'う': 'u',  'え': 'e',  'お': 'o',
  'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
  'さ': 'sa', 'し': 'shi','す': 'su', 'せ': 'se', 'そ': 'so',
  'た': 'ta', 'ち': 'chi','つ': 'tsu','て': 'te', 'と': 'to',
  'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
  'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
  'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
  'や': 'ya',                'ゆ': 'yu',                'よ': 'yo',
  'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
  'わ': 'wa', 'を': 'wo', 'ん': 'n',
  'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
  'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
  'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
  'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
  'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
  'ぁ': 'a',  'ぃ': 'i',  'ぅ': 'u',  'ぇ': 'e',  'ぉ': 'o',
  'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo', 'ゎ': 'wa',
  'ゔ': 'vu'
};

function _blinkKatakanaToHiragana(text) {
  return Array.from(text).map(function(ch) {
    var code = ch.charCodeAt(0);
    if (code >= 0x30A1 && code <= 0x30F6) {
      return String.fromCharCode(code - 0x60);
    }
    return ch;
  }).join('');
}

function _blinkRomanizeCompositionText(text) {
  var source = _blinkKatakanaToHiragana(text || '');
  var result = '';
  var pendingSokuon = false;

  for (var i = 0; i < source.length; i++) {
    var ch = source[i];

    if (/^[\x20-\x7E]$/.test(ch)) {
      result += ch;
      pendingSokuon = false;
      continue;
    }

    if (ch === 'っ') {
      pendingSokuon = true;
      continue;
    }

    if (ch === 'ー') {
      var vowelMatch = result.match(/[aeiou]$/);
      result += vowelMatch ? vowelMatch[0] : '-';
      pendingSokuon = false;
      continue;
    }

    var pair = source.slice(i, i + 2);
    var roman = _blinkKanaDigraphToRomaji[pair];
    if (roman) {
      i += 1;
    } else {
      roman = _blinkKanaToRomaji[ch];
    }

    if (!roman) {
      result += ch;
      pendingSokuon = false;
      continue;
    }

    if (pendingSokuon && /^[bcdfghjklmnpqrstvwxyz]/.test(roman)) {
      result += roman[0];
    }
    pendingSokuon = false;
    result += roman;
  }

  return result;
}

function _blinkPreferredNoConvertText(kb) {
  if (!kb) {
    return '';
  }

  var raw = kb.__blinkRawCompositionText || '';
  var visibleComposition = kb.__blinkCompositionText;
  if (
    !visibleComposition &&
    kb.caret &&
    typeof kb.caret.textContent === 'string' &&
    kb.caret.textContent
  ) {
    visibleComposition = kb.caret.textContent;
  }

  var romanized = visibleComposition
    ? _blinkRomanizeCompositionText(visibleComposition)
    : '';
  var asciiRomanized = romanized && /^[\x20-\x7E]+$/.test(romanized)
    ? romanized
    : '';

  if (raw && asciiRomanized && asciiRomanized.endsWith(raw)) {
    return asciiRomanized;
  }
  if (raw) {
    return raw;
  }
  if (asciiRomanized) {
    return asciiRomanized;
  }

  return '';
}

function term_noConvertComposition() {
  var kb = window._kb;
  var text = _blinkPreferredNoConvertText(kb);
  if (
    !kb ||
    !text
  ) {
    return false;
  }

  _sendStringToNative(text);
  kb.__blinkSkipNextCompositionEnd = true;
  kb.__blinkCompositionText = '';
  kb.__blinkRawCompositionText = '';
  if (
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers._kb
  ) {
    window.webkit.messageHandlers._kb.postMessage({
      op: 'ime',
      type: 'compositionend',
      data: '',
    });
  }
  if (kb.element && typeof kb.element.blur === 'function') {
    kb.element.blur();
  }
  if (kb.caret) {
    if (typeof kb._moveCaret === 'function') {
      kb._moveCaret('');
    }
    kb.caret.innerHTML = '&#8288;';
  }
  if (typeof kb.focus === 'function') {
    setTimeout(function() {
      kb.focus(true);
    }, 0);
  }
  return true;
}

window.term_noConvertComposition = term_noConvertComposition;

class BlinkInternalSKK {
  constructor() {
    this.enabled = true;
    this.mode = 'ascii';
    this.term = null;
    this._buffer = '';
    this._rawBuffer = '';
    this._preedit = '';
    this._pending = '';
    this._candidates = [];
    this._candidateIndex = -1;
    this._root = null;
    this._modeNode = null;
    this._preeditNode = null;
    this._candidateNode = null;
    this._keyDownHandler = null;
    this._romajiMap = {
      kya: 'きゃ', kyu: 'きゅ', kyo: 'きょ',
      sha: 'しゃ', shu: 'しゅ', sho: 'しょ',
      sya: 'しゃ', syu: 'しゅ', syo: 'しょ',
      cha: 'ちゃ', chu: 'ちゅ', cho: 'ちょ',
      cya: 'ちゃ', cyu: 'ちゅ', cyo: 'ちょ',
      nya: 'にゃ', nyu: 'にゅ', nyo: 'にょ',
      hya: 'ひゃ', hyu: 'ひゅ', hyo: 'ひょ',
      mya: 'みゃ', myu: 'みゅ', myo: 'みょ',
      rya: 'りゃ', ryu: 'りゅ', ryo: 'りょ',
      gya: 'ぎゃ', gyu: 'ぎゅ', gyo: 'ぎょ',
      ja: 'じゃ', ju: 'じゅ', jo: 'じょ',
      jya: 'じゃ', jyu: 'じゅ', jyo: 'じょ',
      bya: 'びゃ', byu: 'びゅ', byo: 'びょ',
      pya: 'ぴゃ', pyu: 'ぴゅ', pyo: 'ぴょ',
      fa: 'ふぁ', fi: 'ふぃ', fe: 'ふぇ', fo: 'ふぉ',
      va: 'ゔぁ', vi: 'ゔぃ', vu: 'ゔ', ve: 'ゔぇ', vo: 'ゔぉ',
      tsa: 'つぁ', tsi: 'つぃ', tse: 'つぇ', tso: 'つぉ',
      la: 'ぁ', li: 'ぃ', lu: 'ぅ', le: 'ぇ', lo: 'ぉ',
      lya: 'ゃ', lyu: 'ゅ', lyo: 'ょ',
      ltu: 'っ', xtu: 'っ', xya: 'ゃ', xyu: 'ゅ', xyo: 'ょ',
      xwa: 'ゎ', nn: 'ん',
      ka: 'か', ki: 'き', ku: 'く', ke: 'け', ko: 'こ',
      sa: 'さ', si: 'し', shi: 'し', su: 'す', se: 'せ', so: 'そ',
      ta: 'た', ti: 'ち', chi: 'ち', tu: 'つ', tsu: 'つ', te: 'て', to: 'と',
      na: 'な', ni: 'に', nu: 'ぬ', ne: 'ね', no: 'の',
      ha: 'は', hi: 'ひ', hu: 'ふ', fu: 'ふ', he: 'へ', ho: 'ほ',
      ma: 'ま', mi: 'み', mu: 'む', me: 'め', mo: 'も',
      ya: 'や', yu: 'ゆ', yo: 'よ',
      ra: 'ら', ri: 'り', ru: 'る', re: 'れ', ro: 'ろ',
      wa: 'わ', wi: 'うぃ', we: 'うぇ', wo: 'を',
      ga: 'が', gi: 'ぎ', gu: 'ぐ', ge: 'げ', go: 'ご',
      za: 'ざ', zi: 'じ', ji: 'じ', zu: 'ず', ze: 'ぜ', zo: 'ぞ',
      da: 'だ', di: 'ぢ', du: 'づ', de: 'で', do: 'ど',
      ba: 'ば', bi: 'び', bu: 'ぶ', be: 'べ', bo: 'ぼ',
      pa: 'ぱ', pi: 'ぴ', pu: 'ぷ', pe: 'ぺ', po: 'ぽ',
      a: 'あ', i: 'い', u: 'う', e: 'え', o: 'お',
      '-': 'ー'
    };
    this._romajiPrefixes = {};
    Object.keys(this._romajiMap).forEach(key => {
      for (var i = 1; i < key.length; i++) {
        this._romajiPrefixes[key.slice(0, i)] = true;
      }
    });
    this._sampleDictionary = {
      'にほん': ['日本'],
      'かな': ['仮名'],
      'かんじ': ['漢字'],
      'へんかん': ['変換'],
      'ぶりんく': ['Blink'],
    };
    try {
      var storedEnabled = window.localStorage.getItem('blink.internalSKKEnabled');
      this.enabled = storedEnabled === null ? true : storedEnabled === '1';
      var storedMode = window.localStorage.getItem('blink.internalSKKMode');
      this.mode = storedMode === 'hiragana' ? 'hiragana' : 'ascii';
    } catch (e) {
      this.enabled = true;
      this.mode = 'ascii';
    }
    _debugLog('[BlinkSKK] constructor', {
      enabled: this.enabled,
      mode: this.mode,
    });
  }

  attach(term) {
    this.term = term;
    this._ensureOverlay();
    this._installKeyHandler();
    this._syncTheme();
    this._render();
    _debugLog('[BlinkSKK] attach', {
      enabled: this.enabled,
      mode: this.mode,
    });
  }

  setEnabled(enabled) {
    this.enabled = !!enabled;
    try {
      window.localStorage.setItem('blink.internalSKKEnabled', this.enabled ? '1' : '0');
    } catch (e) {}
    if (!this.enabled) {
      this.reset();
    }
    _debugLog('[BlinkSKK] enabled=' + (this.enabled ? '1' : '0'));
    this._render();
  }

  setMode(mode) {
    var nextMode = mode === 'hiragana' ? 'hiragana' : 'ascii';
    this.mode = nextMode;
    try {
      window.localStorage.setItem('blink.internalSKKMode', nextMode);
    } catch (e) {}
    if (nextMode === 'ascii') {
      this.reset();
    } else {
      this._render();
    }
    _debugLog('[BlinkSKK] mode=' + nextMode);
    return nextMode;
  }

  toggleEnabled() {
    this.setEnabled(!this.enabled);
    return this.enabled;
  }

  reset() {
    this._buffer = '';
    this._rawBuffer = '';
    this._preedit = '';
    this._pending = '';
    this._candidates = [];
    this._candidateIndex = -1;
    this._render();
  }

  hasPendingInput() {
    return this._buffer.length > 0;
  }

  hasCandidateWindow() {
    return this._candidates.length > 0;
  }

  handleSendString(string) {
    if (!this.enabled || !string) {
      _debugLog('[BlinkSKK] handleSendString bypass', {
        enabled: this.enabled,
        mode: this.mode,
        string: string,
      });
      return false;
    }

    if (this.mode !== 'hiragana') {
      _debugLog('[BlinkSKK] ascii passthrough', {string: string});
      return false;
    }

    if (string === '\x7f') {
      if (!this.hasPendingInput()) {
        return false;
      }
      this._candidates = [];
      this._candidateIndex = -1;
      this._buffer = this._buffer.slice(0, -1);
      this._rawBuffer = this._rawBuffer.slice(0, -1);
      this._updateComposition();
      return true;
    }

    if (string === '\r') {
      if (!this.hasPendingInput()) {
        return false;
      }
      this._commit(this._selectedCandidateOrFinalizedText(), 'enter');
      return true;
    }

    if (string === ' ') {
      if (!this.hasPendingInput()) {
        return false;
      }
      if (!this.hasCandidateWindow()) {
        this._openCandidates();
      } else {
        this._moveCandidate(1);
      }
      return true;
    }

    if (string.length !== 1) {
      if (!this.hasPendingInput()) {
        return false;
      }
      this._commit(this._selectedCandidateOrFinalizedText(), 'passthrough');
      return false;
    }

    var lower = string.toLowerCase();
    if (/^[a-z-]$/.test(lower)) {
      this._candidates = [];
      this._candidateIndex = -1;
      this._buffer += lower;
      this._rawBuffer += string;
      this._updateComposition();
      return true;
    }

    if (!this.hasPendingInput()) {
      return false;
    }

    this._commit(this._selectedCandidateOrFinalizedText(), 'flush');
    return false;
  }

  _installKeyHandler() {
    if (this._keyDownHandler) {
      return;
    }

    this._keyDownHandler = this._handleKeyDown.bind(this);
    document.addEventListener('keydown', this._keyDownHandler, true);
  }

  _handleKeyDown(event) {
    if (!this.enabled || this.mode !== 'hiragana' || event.isComposing) {
      return;
    }

    if (
      event.ctrlKey &&
      !event.altKey &&
      !event.metaKey &&
      event.key === ';' &&
      this.hasPendingInput()
    ) {
      event.preventDefault();
      event.stopPropagation();
      this._commitRaw('ctrl:semicolon');
      return;
    }

    if (!this.hasPendingInput()) {
      return;
    }

    if (event.key === ' ' || event.code === 'Space') {
      event.preventDefault();
      event.stopPropagation();
      if (!this.hasCandidateWindow()) {
        this._openCandidates();
      } else {
        this._moveCandidate(event.shiftKey ? -1 : 1);
      }
      return;
    }

    if (!this.hasCandidateWindow()) {
      return;
    }

    if (event.key === 'Tab') {
      event.preventDefault();
      event.stopPropagation();
      this._moveCandidate(event.shiftKey ? -1 : 1);
      return;
    }

    if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
      event.preventDefault();
      event.stopPropagation();
      this._moveCandidate(1);
      return;
    }

    if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
      event.preventDefault();
      event.stopPropagation();
      this._moveCandidate(-1);
      return;
    }

    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      this._closeCandidates();
    }
  }

  _updateComposition() {
    var composition = this._transliterate(this._buffer, false);
    this._preedit = composition.text;
    this._pending = composition.pending;
    this._candidates = [];
    this._render();
  }

  _updateCandidates() {
    var text = this._finalizedText();
    this._candidates = this._lookupCandidates(text);
    this._candidateIndex = this._candidates.length > 0 ? 0 : -1;
    _debugLog('[BlinkSKK] conversion', {text: text, candidates: this._candidates});
    this._render();
  }

  _openCandidates() {
    this._updateCandidates();
  }

  _closeCandidates() {
    this._candidates = [];
    this._candidateIndex = -1;
    this._render();
  }

  _moveCandidate(delta) {
    if (!this.hasCandidateWindow()) {
      return;
    }

    var count = this._candidates.length;
    this._candidateIndex = (this._candidateIndex + delta + count) % count;
    this._render();
  }

  _lookupCandidates(text) {
    if (!text) {
      return [];
    }
    var candidates = this._sampleDictionary[text];
    if (candidates && candidates.length > 0) {
      return candidates;
    }
    return [text];
  }

  _selectedCandidateOrFinalizedText() {
    if (
      this.hasCandidateWindow() &&
      this._candidateIndex >= 0 &&
      this._candidateIndex < this._candidates.length
    ) {
      return this._candidates[this._candidateIndex];
    }
    return this._finalizedText();
  }

  _commit(text, reason) {
    _debugLog('[BlinkSKK] commit', {reason: reason, text: text});
    this.reset();
    if (text) {
      _sendStringToNative(text);
    }
  }

  _commitRaw(reason) {
    var text = this._rawBuffer;
    _debugLog('[BlinkSKK] commit raw', {reason: reason, text: text});
    this.reset();
    if (text) {
      _sendStringToNative(text);
    }
  }

  _finalizedText() {
    return this._transliterate(this._buffer, true).text;
  }

  _isVowel(ch) {
    return /^[aeiou]$/.test(ch);
  }

  _isConsonant(ch) {
    return /^[bcdfghjklmnpqrstvwxyz]$/.test(ch);
  }

  _transliterate(buffer, finalize) {
    var output = '';
    var i = 0;

    while (i < buffer.length) {
      var current = buffer[i];
      var next = buffer[i + 1];

      if (
        next &&
        current === next &&
        this._isConsonant(current) &&
        current !== 'n'
      ) {
        output += 'っ';
        i += 1;
        continue;
      }

      if (current === 'n') {
        if (!next) {
          if (finalize) {
            output += 'ん';
            i += 1;
            continue;
          }
          return {text: output, pending: buffer.slice(i)};
        }
        if (!this._isVowel(next) && next !== 'y') {
          output += 'ん';
          i += 1;
          continue;
        }
      }

      var matched = false;
      for (var len = 3; len >= 1; len--) {
        var chunk = buffer.slice(i, i + len);
        if (this._romajiMap[chunk]) {
          output += this._romajiMap[chunk];
          i += len;
          matched = true;
          break;
        }
      }
      if (matched) {
        continue;
      }

      var pending = buffer.slice(i);
      if (!finalize && this._romajiPrefixes[pending]) {
        return {text: output, pending: pending};
      }

      output += pending[0];
      i += 1;
    }

    return {text: output, pending: ''};
  }

  _ensureOverlay() {
    if (this._root || !this.term || !this.term.cursorOverlayNode_) {
      return;
    }

    this._root = document.createElement('div');
    this._root.id = 'blink-internal-skk';
    this._root.style.position = 'absolute';
    this._root.style.pointerEvents = 'none';
    this._root.style.zIndex = '1001';
    this._root.style.minWidth = '12ch';
    this._root.style.transform =
      'translate3d(calc(var(--hterm-charsize-width) * var(--hterm-cursor-offset-col)), calc(var(--hterm-charsize-height) * (var(--hterm-cursor-offset-row) + 1)), 0)';
    this._root.style.padding = '4px 8px';
    this._root.style.borderRadius = '6px';
    this._root.style.boxShadow = '0 8px 18px rgba(0, 0, 0, 0.25)';
    this._root.style.fontFamily = 'inherit';
    this._root.style.fontSize = '0.95em';
    this._root.style.display = 'none';

    this._modeNode = document.createElement('div');
    this._modeNode.style.fontSize = '0.72em';
    this._modeNode.style.fontWeight = '700';
    this._modeNode.style.letterSpacing = '0.08em';
    this._modeNode.style.textTransform = 'uppercase';
    this._modeNode.style.marginBottom = '4px';

    this._preeditNode = document.createElement('div');
    this._preeditNode.style.fontWeight = '600';
    this._preeditNode.style.whiteSpace = 'pre';

    this._candidateNode = document.createElement('div');
    this._candidateNode.style.marginTop = '4px';
    this._candidateNode.style.opacity = '0.9';
    this._candidateNode.style.fontSize = '0.85em';
    this._candidateNode.style.whiteSpace = 'pre-wrap';

    this._root.appendChild(this._modeNode);
    this._root.appendChild(this._preeditNode);
    this._root.appendChild(this._candidateNode);
    this.term.cursorOverlayNode_.appendChild(this._root);
  }

  _syncTheme() {
    if (!this._root || !this.term || !this.term.scrollPort_) {
      return;
    }
    this._root.style.background = '#000000';
    this._root.style.color = '#ffffff';
    this._root.style.border = '1px solid #28C6E4';
    this._modeNode.style.color = this.mode === 'hiragana' ? '#28C6E4' : '#FFD166';
    this._preeditNode.style.color = '#ffffff';
    this._candidateNode.style.color = '#ffffff';
  }

  _render() {
    if (!this._root) {
      return;
    }

    this._syncTheme();

    this._modeNode.textContent = this.mode === 'hiragana' ? 'IME: HIRA' : 'IME: ASCII';
    this._preeditNode.textContent = this._preedit || this._pending;
    if (this._candidates.length > 0) {
      this._candidateNode.textContent = '';
      for (var i = 0; i < this._candidates.length; i++) {
        if (i > 0) {
          this._candidateNode.appendChild(document.createTextNode(' / '));
        }
        var candidateSpan = document.createElement('span');
        candidateSpan.textContent = this._candidates[i];
        if (i === this._candidateIndex) {
          candidateSpan.style.color = '#28C6E4';
          candidateSpan.style.fontWeight = '700';
        } else {
          candidateSpan.style.color = '#ffffff';
        }
        this._candidateNode.appendChild(candidateSpan);
      }
    } else {
      this._candidateNode.textContent = '';
    }
    if (!this.enabled) {
      this._root.style.display = 'none';
      return;
    }

    this._root.style.display = 'block';
    this._preeditNode.style.display = (this._preedit || this._pending) ? 'block' : 'none';
    this._candidateNode.style.display = this._candidates.length > 0 ? 'block' : 'none';
  }
}

window.blinkInternalSKK = new BlinkInternalSKK();
window.term_setInternalSKK = function(enabled) {
  window.blinkInternalSKK.setEnabled(enabled);
};
window.term_setInternalSKKMode = function(mode) {
  return window.blinkInternalSKK.setMode(mode);
};
window.term_toggleInternalSKK = function() {
  return window.blinkInternalSKK.toggleEnabled();
};

hterm.Terminal.IO.prototype.sendString = function(string) {
  if (window.blinkInternalSKK && window.blinkInternalSKK.handleSendString(string)) {
    return;
  }
  _sendStringToNative(string);
};

hterm.msg = function() {}; // TODO: show messages

function _colorComponents(colorStr) {
  if (!colorStr) {
    return [0, 0, 0]; // Default is black
  }

  return colorStr
    .replace(/[^0-9,]/g, '')
    .split(',')
    .map(s => parseInt(s));
}

// Before we fully load hterm. We set options here.
var _prefs = new hterm.PreferenceManager('blink');
var t = {prefs_: _prefs}; // <- `t` will become actual hterm instance after decorate.

function term_set(key, value) {
  _prefs.set(key, value);
}

function term_get(key) {
  return _prefs.get(key);
}

function term_setupDefaults() {
  term_set('copy-on-select', false);
  term_set('audible-bell-sound', '');
  term_set('receive-encoding', 'raw'); // we are UTF8
  term_set('allow-images-inline', true); // need to make it work
  term_set('scroll-wheel-may-send-arrow-keys', true)
}

function term_processKB(str) {
  if (!t.prompt) {
    return;
  }
  if (str) {
    t.prompt.processInput(str);
  }
}

function term_displayInput(str, display) {
  if (!t || !t.accessibilityReader_) {
    return;
  }
  
  t.accessibilityReader_.hasUserGesture = true;
  
  if (!display) {
    return;
  }
  
  if (str && !t.prompt._secure) {
    window.KeystrokeVisualizer.processInput(str);
  }
}


function term_setup(accessibilityEnabled) {
  t = new hterm.Terminal('blink');
  _debugLog('[BlinkSKK] term_setup');

  t.onTerminalReady = function() {
    _debugLog('[BlinkSKK] onTerminalReady');
    window.installKB(t, t.scrollPort_.screen_);
    term_setAutoCarriageReturn(true);
    term_setClipboardWrite(false);

    t.setCursorVisible(true);
    t.io.onTerminalResize = function(cols, rows) {
      _postMessage('sigwinch', {cols, rows});
      if (t.prompt) {
        t.prompt.resize();
      }
    };

    var size = {
      cols: t.screenSize.width,
      rows: t.screenSize.height,
    };
    
    document.body.style.backgroundColor =
      t.scrollPort_.screen_.style.backgroundColor;
    var bgColor = _colorComponents(t.scrollPort_.screen_.style.backgroundColor);
    
    t.keyboard.characterEncoding = 'raw'; // we are UTF8. Fix for #507
    t.uninstallKeyboard();
    
    _postMessage('terminalReady', {size, bgColor});

    if (window.KeystrokeVisualizer) {
      window.KeystrokeVisualizer.enable();
    }
    t.setAccessibilityEnabled(accessibilityEnabled);
    if (window.blinkInternalSKK) {
      window.blinkInternalSKK.attach(t);
    }
  };

  t.decorate(document.getElementById('terminal'));
}

function term_init(accessibilityEnabled, lockdownMode) {
  term_setupDefaults();
  try {
    applyUserSettings();
    //    var bgColor = term_get('background-color');
    //    document.body.style.backgroundColor = bgColor;
    //    document.body.parentNode.style.backgroundColor = bgColor;
    if (lockdownMode) {
      term_setup(accessibilityEnabled);
    } else {
      waitForFontFamily(term_setup);
    }
  } catch (e) {
    _postMessage('alert', {
      title: 'Error',
      message:
        'Failed to setup theme. Please check syntax of your theme.\n' +
        e.toString(),
    });
    term_setup(accessibilityEnabled);
  }
}

var _requestId = 0;
var _requestsMap = {};

class ApiRequest {
  constructor(name, request) {
    this.id = _requestId++;
    request.id = this.id;
    var self = this;
    this.promise = new Promise(function(resolve, reject) {
        self.resolve = resolve;
        self.reject = reject;
    });
    _requestsMap[this.id] = self
    _postMessage("api", {name, request: JSON.stringify(request)} );
    
    this.then = this.promise.then.bind(this.promise);
    this.catch = this.promise.catch.bind(this.promise);
  }
  
  cancel() {
    this.resolve(null);
    delete _requestsMap[this.id];
  }
}

function term_apiRequest(name, request) {
  return new ApiRequest(name, request)
}

function term_apiResponse(name, response) {
  var res = JSON.parse(response);
  var req = _requestsMap[res.requestId];
  if (!req) {
    return;
  }
  delete _requestsMap[req.id];
  req.resolve(res)
}


window.term_apiRequest = term_apiRequest;
window.term_apiResponse = term_apiResponse;

function term_write(data) {
  t.interpret(data);
}

function term_paste(str) {
  t.onPaste_({text: str || ''});
}

var _utf8TextDecoder = new TextDecoder('utf8');
function term_write_b64(b64str) {
  var bytes = base64js.toByteArray(b64str); // b64_to_uint8_array(b64str);
  var data = _utf8TextDecoder.decode(bytes);
  t.interpret(data);
};

function b64_to_uint8_array(b64Str) {
  var s = atob(b64Str);
  var len = s.length;
  var res = new Uint8Array(len);
  for (var i = 0; i < len; i++) {
    res[i] = s.charCodeAt(i);
  }
  return res;
}

function term_clear() {
  t.clear();
}

function term_reset() {
  t.reset();
}

function term_focus() {
  t.onFocusChange__(true);
}

function term_blur() {
  t.onFocusChange__(false);
}

function _setTermCoordinates(event, x, y) {
  // One based row/column stored on the mouse event.
  var ty = (y / t.scrollPort_.characterSize.height | 0) + 1;
  var tx = (x / t.scrollPort_.characterSize.width | 0) + 1;
//  console.log(`x:${x},y: ${y}, col:${tx}, row:${ty}`);
  event.terminalRow = ty;
  event.terminalColumn = tx;
}

function term_reportMouseClick(x, y, buttons, display) {
  if (!t.prompt) {
    return;
  }

  var event = new MouseEvent(name, {buttons});
  _setTermCoordinates(event, x, y);
  if (!t.prompt.processMouseClick(event)) {
    term_reportMouseEvent('mousedown', x, y, 1);
    term_reportMouseEvent('mouseup', x, y, 1);
  }
                                  
  if (display) {
     term_displayInput("👆", display);
  }
}

function term_reportMouseEvent(name, x, y, buttons) {
  if (!t.prompt) {
    return;
  }

  var event = new MouseEvent(name, {buttons});
  _setTermCoordinates(event, x, y);
  t.onMouse(event);
}

function term_reportWheelEvent(name, x, y, deltaX, deltaY) {
  if (!t.prompt) {
    return;
  }

  var event = new WheelEvent(name, {clientX: x, clientY: y, deltaX, deltaY});
  t.onMouse_Blink(event);
}

function term_setWidth(cols) {
  t.setWidth(cols);
}

function term_increaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size + 1 + 'px');
}

function term_decreaseFontSize() {
  var size = t.getFontSize();
  term_setFontSize(size - 1 + 'px');
}

function term_resetFontSize() {
  term_setFontSize();
}

function term_scale(scale) {
  var minScale = 0.3;
  var maxScale = 3.0;
  scale = Math.max(minScale, Math.min(maxScale, scale));
  var fontSize = t.getFontSize();
  var newFontSize = Math.round(fontSize * scale);
  if (fontSize == newFontSize) {
    return;
  }
  term_setFontSize(newFontSize);
}

function term_setFontSize(size) {
  term_set('font-size', size);
  _postMessage('fontSizeChanged', {size: parseInt(size)});
}

function term_setFontFamily(name, fontSizeDetectionMethod) {
  window.fontSizeDetectionMethod = fontSizeDetectionMethod;
  term_set('font-family', name + ', "DejaVu Sans Mono"');
}

function term_setClipboardWrite(state) {
  if (state === false) {
    t.vt.enableClipboardWrite = false;
  } else {
    t.vt.enableClipboardWrite = true;
  }
}

function term_appendUserCss(css) {
  var style = document.createElement('style');

  style.type = 'text/css';
  style.appendChild(document.createTextNode(css));

  document.head.appendChild(style);
}

function term_loadFontFromCss(url, name) {
  WebFont.load({
    custom: {
      families: [name],
      urls: [url],
    },
    active: function() {
      t.syncFontFamily();
    },
  });
  term_setFontFamily(name);
}

function term_getCurrentSelection() {
  const selection = document.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.type === 'Caret') {
    return {base: '', offset: 0, text: ''};
  }

  const r = selection.getRangeAt(0).getBoundingClientRect();

  const rect = `{{${r.x}, ${r.y}},{${r.width},${r.height}}}`;

  return {
    base: selection.baseNode.textContent,
    offset: selection.baseOffset,
    text: selection.toString() || "",
    rect,
  };
}

function _modifySelectionByLine(direction) {
  var selection = document.getSelection();
  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  var dy =
    direction === 'left'
      ? -t.scrollPort_.characterSize.height
      : t.scrollPort_.characterSize.height;
  var dx = t.scrollPort_.characterSize.width;
  var range = selection.getRangeAt(0);

  var topLeft = true;
  if (fNode === aNode) {
    topLeft = fOffset < aOffset;
  } else {
    topLeft = range.compareNode(selection.focusNode) !== Range.NODE_AFTER;
  }

  if (topLeft) {
    // top left
    var rect = _filteredRects(range)[0];
    var point = {x: rect.left, y: rect.top + Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (!newRange) {
      selection.modify('extend', direction, 'line');
    } else {
      if (newRange.startContainer.textContent.length <= newRange.startOffset) {
        if (
          newRange.startContainer.nodeName === 'X-ROW' &&
          newRange.startOffset === 0
        ) {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            newRange.startOffset,
          );
          selection.modify('extend', 'left', 'character');
        } else {
          selection.setBaseAndExtent(
            aNode,
            aOffset,
            newRange.startContainer,
            Math.max(newRange.startOffset - 1, 0),
          );
        }
      } else {
        selection.setBaseAndExtent(
          aNode,
          aOffset,
          newRange.startContainer,
          newRange.startOffset,
        );
      }
    }
  } else {
    // bottom right
    var rects = _filteredRects(range);
    var rect = rects[rects.length - 1];
    var point = {x: rect.right, y: rect.bottom - Math.abs(dy) * 0.5};
    var newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    if (newRange == null) {
      point.x -= dx * 0.5;
    }
    newRange = document.caretRangeFromPoint(point.x, point.y + dy);
    selection.setBaseAndExtent(
      aNode,
      aOffset,
      newRange.startContainer,
      newRange.startOffset,
    );
  }
}

function _filteredRects(range) {
  var res = [];
  var rects = range.getClientRects();
  for (var i = 0; i < rects.length; i++) {
    var r = rects[i];
    if (r.width > 0) {
      res.push(r);
    }
  }
  return res;
}

function term_modifySelection(direction, granularity) {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  var fNode = selection.focusNode;
  var fOffset = selection.focusOffset;
  var aNode = selection.anchorNode;
  var aOffset = selection.anchorOffset;

  if (granularity === 'line') {
    _modifySelectionByLine(direction);
    if (selection.isCollapsed) {
      selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
      _modifySelectionByLine(direction);
    }

    return;
  }

  selection.modify('extend', direction, granularity);

  // we collapse selection, so swap direction and rerun modification again
  if (selection.isCollapsed) {
    selection.setBaseAndExtent(fNode, fOffset, aNode, aOffset);
    selection.modify('extend', direction, granularity);
  }
}

function term_modifySideSelection() {
  var selection = document.getSelection();
  if (!selection || selection.rangeCount === 0) {
    return;
  }

  selection.setBaseAndExtent(
    selection.focusNode,
    selection.focusOffset,
    selection.anchorNode,
    selection.anchorOffset,
  );
}

function term_cleanSelection() {
  document.getSelection().removeAllRanges();
}

function waitForFontFamily(callback) {
  const fontFamily = term_get('font-family');
  if (!fontFamily) {
    return callback();
  }

  const families = fontFamily.split(/\s*,\s*/);

  WebFont.load({
    custom: {families},
    active: callback,
    inactive: callback,
  });
}

function term_applySexyTheme(theme) {
  term_set('color-palette-overrides', theme.color);
  term_set('foreground-color', theme.foreground);
  term_set('background-color', theme.background);
}

function term_setAutoCarriageReturn(state) {
  t.setAutoCarriageReturn(state);
}

function term_restore() {
  t.primaryScreen_.textAttributes.reset();
  t.setVTScrollRegion(null, null);
  t.setCursorVisible(true);
}
