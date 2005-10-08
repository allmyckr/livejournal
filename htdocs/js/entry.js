var layout_mode = "thin";
var sc_old_border_style;
var shift_init = "true";

if (! ("$" in window))
    $ = function(id) {
        if (document.getElementById)
           return document.getElementById(id);
        return null;
    };


function shift_contents() {
    if (! document.getElementById) { return false; }
    var infobox = $("infobox");
    var column_one = $("column_one_td");
    var column_two = $("column_two_td");
    var column_one_table = $("column_one_table");
    var column_two_table = $("column_two_table");

    var shifting_rows = new Array();

    if (shift_init == "true") {
        shift_init = "false";
        bsMacIE5Fix = document.createElement("tr");
        bsMacIE5Fix.style.display = "none";
        sc_old_border_style = column_one.style.borderRight;
    }

    var width;
    if (self.innerWidth) {
        width = self.innerWidth;
    } else if (document.documentElement && document.documentElement.clientWidth) {
	width = document.documentElement.clientWidth;
    } else if (document.body) {
        width = document.body.clientWidth;
    }

    if (width < 1000) {
        if (layout_mode == "thin" && shift_init == "true") { return true; }

        layout_mode = "thin";
        column_one.style.borderRight = "0";
        column_two.style.display = "none";

        infobox.style.display = "none";
        column_two_table.lastChild.appendChild(bsMacIE5Fix);

        column_one_table.lastChild.appendChild($("backdate_row"));
        column_one_table.lastChild.appendChild($("comment_settings_row"));
        column_one_table.lastChild.appendChild($("comment_screen_settings_row"));
        if ($("userpic_list_row")) {
            column_one_table.lastChild.appendChild($("userpic_list_row"));
        }
    } else {
        if (layout_mode == "wide") { return false; }
        layout_mode = "wide";
        column_one.style.borderRight = sc_old_border_style;
        column_two.style.display = "block";

        infobox.style.display = "block";
        column_one_table.lastChild.appendChild(bsMacIE5Fix);

        column_two_table.lastChild.appendChild($("backdate_row"));
        column_two_table.lastChild.appendChild($("comment_settings_row"));
        column_two_table.lastChild.appendChild($("comment_screen_settings_row"));
        if ($("userpic_list_row")) {
            column_two_table.lastChild.appendChild($("userpic_list_row"));
        }
    }
}

function enable_rte () {
    if (! document.getElementById) return false;
    
    f = document.updateForm;
    if (! f) return false;
    f.switched_rte_on.value = 1;
    f.submit();
    return false;
}
// Maintain entry through browser navigations.
// IE does this onBlur, Gecko onUnload.
function save_entry () {
    if (! document.getElementById) return false;
    
    f = document.updateForm;
    if (! f) return false;
    rte = $('rte');
    if (! rte) return false;
    content = rte.contentWindow.document.body.innerHTML;
    f.saved_entry.value = content;
    return false;
}

// Restore saved_entry text across platforms.
// This is only used for IE, Gecko browser support is in the RTE library.
function restore_entry () {
    if (! document.getElementById) return false;
    f = document.updateForm;
    if (! f) return false;
    rte = $('rte');
    if (! rte) return false;
    if (document.updateForm.saved_entry.value == "") return false;
    setTimeout(
               function () {
                   $('rte').contentWindow.document.body.innerHTML = 
                       document.updateForm.saved_entry.value;
               }, 100);
    return false;
}

function pageload (dotime) {
    restore_entry();

    if (dotime) settime();
    if (!document.getElementById) return false;

    var remotelogin = $('remotelogin');
    if (! remotelogin) return false;
    var remotelogin_content = $('remotelogin_content');
    if (! remotelogin_content) return false;
    remotelogin_content.onclick = altlogin;

    f = document.updateForm;
    if (! f) return false;

    var userbox = f.user;
    if (! userbox) return false;
    if (userbox.value) altlogin();

    return false;
}

function customboxes (e) {
    if (! e) var e = window.event;
    if (! document.getElementById) return false;
    
    f = document.updateForm;
    if (! f) return false;
    
    var custom_boxes = $('custom_boxes');
    if (! custom_boxes) return false;
    
    if (f.security.selectedIndex != 3) {
        custom_boxes.style.display = 'none';
        return false;
    }

    var altlogin_username = $('altlogin_username');    
    if (altlogin_username != undefined && (altlogin_username.style.display == 'table-row' ||
                                           altlogin_username.style.display == 'block')) {
        f.security.selectedIndex = 0;
        custom_boxes.style.display = 'none';
        alert("Custom security is only available when posting as the logged in user.");
    } else {
        custom_boxes.style.display = 'block';
    }
    
    if (e) {
        e.cancelBubble = true;
        if (e.stopPropagation) e.stopPropagation();
    }
    return false;
}

function altlogin (e) {
    var agt   = navigator.userAgent.toLowerCase();
    var is_ie = ((agt.indexOf("msie") != -1) && (agt.indexOf("opera") == -1));

    if (! e) var e = window.event;
    if (! document.getElementById) return false;
    
    var altlogin_username = $('altlogin_username');
    if (! altlogin_username) return false;
    if (is_ie) { altlogin_username.style.display = 'block'; } else { altlogin_username.style.display = 'table-row'; }

    var altlogin_password = $('altlogin_password');
    if (! altlogin_password) return false;
    if (is_ie) { altlogin_password.style.display = 'block'; } else { altlogin_password.style.display = 'table-row'; }
    
    var remotelogin = $('remotelogin');
    if (! remotelogin) return false;
    remotelogin.style.display = 'none';
    
    var usejournal_list = $('usejournal_list');
    if (! usejournal_list) return false;
    usejournal_list.style.display = 'none';

    var readonly = $('readonly');
    var userbox = f.user;
    if (!userbox.value && readonly) {
        readonly.style.display = 'none';
    }

    var userpic_list = $('userpic_list_row');
    if (userpic_list) {
        userpic_list.style.display = 'none';
        var userpic_preview = $('userpic_preview');
        userpic_preview.style.display = 'none';
    }

    var mood_preview = $('mood_preview');
    mood_preview.style.display = 'none';

    f = document.updateForm;
    if (! f) return false;
    f.action = 'update.bml?altlogin=1';
    
    var custom_boxes = $('custom_boxes');
    if (! custom_boxes) return false;
    custom_boxes.style.display = 'none';
    f.security.selectedIndex = 0;
    f.security.removeChild(f.security.childNodes[3]);

    if (e) {
        e.cancelBubble = true;
        if (e.stopPropagation) e.stopPropagation();
    }

    return false;    
}
function settime() {
    function twodigit (n) {
        if (n < 10) { return "0" + n; }
        else { return n; }
    }
    
    now = new Date();
    if (! now) return false;
    f = document.updateForm;
    if (! f) return false;
    
    f.date_ymd_yyyy.value = now.getYear() < 1900 ? now.getYear() + 1900 : now.getYear();
    f.date_ymd_mm.selectedIndex = twodigit(now.getMonth());
    f.date_ymd_dd.value = twodigit(now.getDate());
    f.hour.value = twodigit(now.getHours());
    f.min.value = twodigit(now.getMinutes());
    
    return false;
}


///////////////////// Insert Object code


var InOb = new Object;

InOb.fail = function (msg) {
    alert("FAIL: " + msg);
    return ;
};

// image upload stuff
InOb.onUpload = function (url, width, height) {
    var ta = $("updateForm");
    if (! ta) return InOb.fail("no updateform");
    ta = ta.event;
    ta.value = ta.value + "\n<img src=\"" + url + "\" width=\"" + width + "\" height=\"" + height + "\" />";
};


InOb.onInsURL = function (url) {
        var ta = $("updateForm");
        var fail = function (msg) {
            alert("FAIL: " + msg);
            return 0;
        };
        if (! ta) return fail("no updateform");
        ta = ta.event;
        ta.value = ta.value + "\n<img src=\"" + url + "\" />";
};


var currentPopup;        // set when we make the iframe
var currentPopupWindow;  // set when the iframe registers with us and we setup its handlers
function onInsertObject (include) {
    InOb.onClosePopup();

    //var iframe = document.createElement("iframe");
    var iframe = document.createElement("div");
    iframe.id = "updateinsobject";
    iframe.className = 'updateinsobject';
    iframe.style.overflow = "hidden";
    iframe.style.position = "absolute";
    iframe.style.left = 75 + "px";
    iframe.style.top = 200 + "px";
    iframe.style.border = "0";
    //iframe.style.borderStyle = "solid";
    //iframe.style.borderColor = "#bbddff";
    iframe.style.backgroundColor = "#fff";
    iframe.style.width = "700px"; //"60em";
    iframe.style.height = "300px"; //"20em";

    //iframe.src = include;
    iframe.innerHTML = "<iframe id='popupsIframe' style='border:0' width='100%' height='100%' src='" + include + "'></iframe>";

    currentPopup = iframe;
    document.body.appendChild(iframe);

    setTimeout(function () { iframe.src = include; }, 500);
}

// the select's onchange:
InOb.handleInsertSelect = function () {
    var objsel = $('insobjsel');
    if (! objsel) { alert('can\'t get insert select'); return false; }

    var selected = objsel.selectedIndex;
    var include;

    objsel.selectedIndex = 0;

    if (selected == 0) {
        return true;
    } else if (selected == 1) {
        include = 'imgupload.bml';
    } else {
        alert('Unknown index selected');
        return false;
    }

    onInsertObject(include);

    return true;
};

InOb.onClosePopup = function () {
    if (! currentPopup) return;
    document.body.removeChild(currentPopup);
    currentPopup = null;
};

InOb.setupIframeHandlers = function () {
    var ife = $("popupsIframe");  //currentPopup;
    if (! ife) { alert('handler without a popup?'); return false; }
    var ifw = ife.contentWindow;
    currentPopupWindow = ifw;
    if (! ifw) {
        alert("no content window?");
        return;
    }

    var el;

    el = ifw.document.getElementById("fromurl");
    if (el) el.onfocus = function () { return InOb.selectRadio("fromurl"); };
    el = ifw.document.getElementById("fromurlentry");
    if (el) el.onfocus = function () { return InOb.selectRadio("fromurl"); };
    el = ifw.document.getElementById("fromfile");
    if (el) el.onfocus = function () { return InOb.selectRadio("fromfile"); };
    el = ifw.document.getElementById("fromfileentry");
    if (el) el.onclick = el.onfocus = function () { return InOb.selectRadio("fromfile"); };
    el = ifw.document.getElementById("fromfb");
    if (el) el.onfocus = function () { return InOb.selectRadio("fromfb"); };

};

InOb.selectRadio = function (which) {
    if (! currentPopup) { alert('no popup');
                          alert(window.parent.currentPopup);
 return false; }
    if (! currentPopupWindow) { alert('no popup window'); return false; }

    var radio = currentPopupWindow.document.getElementById(which);
    if (! radio) { alert('no radio button'); return false; }
    radio.checked = true;

    var fromurl  = currentPopupWindow.document.getElementById('fromurlentry');
    var fromfile = currentPopupWindow.document.getElementById('fromfileentry');
    var submit   = currentPopupWindow.document.getElementById('insbutton');
    if (! submit) { alert('no submit button'); return false; }

    // clear stuff
    if (which != 'fromurl') {
        fromurl.value = '';
    }

    if (which != 'fromfile') {
        var filediv = currentPopupWindow.document.getElementById('filediv');
        filediv.innerHTML = filediv.innerHTML;
    }

    // focus and change next button
    if (which == "fromurl") {
        submit.value = 'Insert';
        fromurl.focus();
    }

    else if (which == "fromfile") {
        submit.value = 'Upload';
        fromfile.focus();
    }

    else if (which == "fromfb") {
        submit.value = "Next -->";  // &#x2192 is a right arrow
        fromfile.focus();
    }

    return true;
};

InOb.onSubmit = function () {
    var fileradio = currentPopupWindow.document.getElementById('fromfile');
    var urlradio  = currentPopupWindow.document.getElementById('fromurl');
    if (! fileradio) { alert('no file radio button'); return false; }
    if (! urlradio)  { alert('no url radio button'); return false; }

    var form = currentPopupWindow.document.getElementById('insobjform');
    if (! form)  { alert('no form'); return false; }

    var setEnc = function (vl) {
        form.enctype = vl;
        if (form.setAttribute) {
            form.setAttribute("enctype", vl);
        }
    };

    if (fileradio.checked) {
        form.action = currentPopupWindow.fileaction;
        setEnc("multipart/form-data");
        return true;
    } else if (urlradio.checked) {
        setEnc("");
        form.action = currentPopupWindow.urlaction;
        return true;
    } else {
        alert('unknown radio button checked');
        return false;
    }
};

