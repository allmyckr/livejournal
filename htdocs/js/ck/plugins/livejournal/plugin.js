(function(){function r(c){function g(){var a=this.getAttribute("lj-cmd");d.hasOwnProperty(a)&&(k[a].node=d[a].node,(new CKEDITOR.dom.selection(c.document)).selectElement(k[a].node),p=!0,c.execCommand(a),CKEDITOR.note.hide(!0));return!1}function m(){window.switchedRteOn||CKEDITOR.note.hide(!0);if(b){d=e;e=null;var c="",h;for(h in d)d.hasOwnProperty(h)&&(c+='<div class="noteItem">'+d[h].content+"</div>");f.innerHTML=decodeURIComponent(c);c=f.getElementsByTagName("a");h=0;for(var q=c.length;h<q;h++){var i= c[h];k.hasOwnProperty(i.getAttribute("lj-cmd"))&&(i.onclick=g)}}else d=null;o(b);a=null}var a,b,d,e,f=document.createElement("lj-note"),j="string"!=typeof document.body.style.opacity,o=function(){function a(){var b=o.shift(),b=(d?b.time/c:-(b.time/c-1)).toFixed(1);o.length||(b=d?1:0);j?f.style.filter=1<=b?null:"progid:DXImageTransform.Microsoft.Alpha(opacity="+100*b+")":f.style.opacity=b;0==b&&f&&f.parentNode&&f.parentNode.removeChild(f)}var c=100,b=60*c/1E3,o=[],d,l=document.getElementById("draft-container")|| document.body;return function(c){if((d=c)&&f.parentNode)j?f.style.filter=null:f.style.opacity=1;else for(c=1;c<=b;c++){var h=Math.floor(1E3/60)*c;o.push({time:h,timer:setTimeout(a,h)})}l.appendChild(f);f.style.marginTop=-f.offsetHeight/2+"px";f.style.marginLeft=-f.offsetWidth/2+"px"}}();f.className="note-popup";f.onmouseout=function(){(!d||!d.cmd)&&CKEDITOR.note.hide()};f.onmouseover=function(){a&&!b&&(b=1,a=clearTimeout(a))};j?f.style.filter="progid:DXImageTransform.Microsoft.Alpha(opacity=0)":f.style.opacity= 0;CKEDITOR.note={show:function(c,o){if((o||c!=e)&&window.switchedRteOn)a&&(a=clearTimeout(a)),b=1,e=c,!0===o?m():a=setTimeout(m,1E3)},hide:function(c){b&&(b=0,a&&(a=clearTimeout(a)),f.parentNode&&(!0===c?m():a=setTimeout(m,500)))}}}var m=[{label:top.CKLang.LJLike_button_facebook,id:"facebook",abbr:"fb",html:'<span class="lj-like-item fb">'+top.CKLang.LJLike_button_facebook+"</span>",htmlOpt:'<li class="like-fb"><input type="checkbox" id="like-fb" /><label for="like-fb">'+top.CKLang.LJLike_button_facebook+ "</label></li>"},{label:top.CKLang.LJLike_button_twitter,id:"twitter",abbr:"tw",html:'<span class="lj-like-item tw">'+top.CKLang.LJLike_button_twitter+"</span>",htmlOpt:'<li class="like-tw"><input type="checkbox" id="like-tw" /><label for="like-tw">'+top.CKLang.LJLike_button_twitter+"</label></li>"},{label:top.CKLang.LJLike_button_google,id:"google",abbr:"go",html:'<span class="lj-like-item go">'+top.CKLang.LJLike_button_google+"</span>",htmlOpt:'<li class="like-go"><input type="checkbox" id="like-go" /><label for="like-go">'+ top.CKLang.LJLike_button_google+"</label></li>"},{label:top.CKLang.LJLike_button_vkontakte,id:"vkontakte",abbr:"vk",html:'<span class="lj-like-item vk">'+top.CKLang.LJLike_button_vkontakte+"</span>",htmlOpt:window.isSupUser?'<li class="like-vk"><input type="checkbox" id="like-vk" /><label for="like-vk">'+top.CKLang.LJLike_button_vkontakte+"</label></li>":""},{label:top.CKLang.LJLike_button_give,id:"livejournal",abbr:"lj",html:'<span class="lj-like-item lj">'+top.CKLang.LJLike_button_give+"</span>", htmlOpt:'<li class="like-lj"><input type="checkbox" id="like-lj" /><label for="like-lj">'+top.CKLang.LJLike_button_give+"</label></li>"}],k={LJPollLink:{html:encodeURIComponent(top.CKLang.Poll_PollWizardNotice+'<br /><a href="#" lj-cmd="LJPollLink">'+top.CKLang.Poll_PollWizardNoticeLink+"</a>")},LJLike:{html:encodeURIComponent(top.CKLang.LJLike_WizardNotice+'<br /><a href="#" lj-cmd="LJLike">'+top.CKLang.LJLike_WizardNoticeLink+"</a>")},LJUserLink:{html:encodeURIComponent(top.CKLang.LJUser_WizardNotice+ '<br /><a href="#" lj-cmd="LJUserLink">'+top.CKLang.LJUser_WizardNoticeLink+"</a>")},LJLink:{html:encodeURIComponent(top.CKLang.LJLink_WizardNotice+'<br /><a href="#" lj-cmd="LJLink">'+top.CKLang.LJLink_WizardNoticeLink+"</a>")},image:{html:encodeURIComponent(top.CKLang.LJImage_WizardNotice+'<br /><a href="#" lj-cmd="image">'+top.CKLang.LJImage_WizardNoticeLink+"</a>")},LJCut:{html:encodeURIComponent(top.CKLang.LJCut_WizardNotice+'<br /><a href="#" lj-cmd="LJCut">'+top.CKLang.LJCut_WizardNoticeLink+ "</a>")},LJSpoiler:{html:encodeURIComponent(top.CKLang.LJSpoiler_WizardNotice+'<br /><a href="#" lj-cmd="LJSpoiler">'+top.CKLang.LJSpoiler_WizardNoticeLink+"</a>")}},n={},p,g=CKEDITOR.dtd;g.$block["lj-template"]=1;g.$block["lj-raw"]=1;g.$block["lj-cut"]=1;g.$block["lj-spoiler"]=1;g.$block["lj-poll"]=1;g.$block["lj-pq"]=1;g.$block["lj-pi"]=1;g.$nonEditable["lj-template"]=1;g["lj-template"]={};g["lj-map"]={};g["lj-raw"]=g.div;g["lj-poll"]={"lj-pq":1};g["lj-pq"]={"#":1,"lj-pi":1};g["lj-pi"]={"#":1}; CKEDITOR.tools.extend(g["lj-cut"]={},g.$block);CKEDITOR.tools.extend(g["lj-spoiler"]={},g.$block);g.$block.iframe=g.$inline.iframe;delete g.$inline.iframe;CKEDITOR.tools.extend(g.div,g.$block);CKEDITOR.tools.extend(g.$body,g.$block);delete g["lj-cut"]["lj-cut"];CKEDITOR.plugins.add("livejournal",{init:function(c){function g(a){var b=a.data.element||a.data.getTarget();for(1!=b.type&&(b=b.getParent());b;){var h=b.getAttribute("lj-cmd");if(k.hasOwnProperty(h)){var d=c.getCommand(h);if(d.state==CKEDITOR.TRISTATE_ON){var i= new CKEDITOR.dom.selection(c.document);k[h].node=b.is("body")?new CKEDITOR.dom.element.get(b.getWindow().$.frameElement):b;i.selectElement(k[h].node);a.data.dialog="";p=!0;d.exec();break}}b=b.getParent()}}function t(a){this.$!=c.document.$&&(this.$.className=(this.frame.getAttribute("lj-class")||"")+" lj-selected","LJPollLink"==this.getAttribute("lj-cmd")&&this.frame.setStyle("height",this.getDocument().$.body.scrollHeight+"px"),(new CKEDITOR.dom.selection(c.document)).selectElement(this.frame)); 1==a.data.getKey()&&a.data.preventDefault()}function a(a){if(46==a.data.getKey())for(var a=(new CKEDITOR.dom.selection(c.document)).getRanges(),b=a.length;b--;)a[b].deleteContents()}function b(){var b=this.$.contentWindow.document,c=new CKEDITOR.dom.element.get(b.body);c.on&&(c.on("dblclick",g),c.on("click",t),c.on("keyup",a),"LJPollLink"==this.getAttribute("lj-cmd")&&this.hasAttribute("style")&&(b.body.className="lj-poll lj-poll-open"));b=new CKEDITOR.dom.element.get(b);b.frame=c.frame=this}function d(){var a= c.document.getElementsByTag("iframe"),d=a.count(),h,f,i,e,l;for(p=!1;d--;)h=a.getItem(d),f=h.getAttribute("lj-cmd"),i=h.$.contentWindow,e=i.document,l=h.getAttribute("lj-style")||"",h.removeListener("load",b),h.on("load",b),e.open(),e.write('<!DOCTYPE html><html style="'+l+'"><head><style type="text/css">'+CKEDITOR.styleText+'</style></head><body scroll="no" class="'+(h.getAttribute("lj-class")||"")+'" style="'+l+'" '+(f?'lj-cmd="'+f+'"':"")+">"+decodeURIComponent(h.getAttribute("lj-content")||"")+ "</body></html>"),e.close()}function e(a){if(!0===c.onSwitch)delete c.onSwitch;else{var b,h="click"==a.name,d="selectionChange"==a.name||h,i=a.data.element||a.data.getTarget(),f;h&&(1==a.data.getKey()||0==a.data.$.button)&&a.data.preventDefault();1!=i.type&&(i=i.getParent());a=i;if(d){var i=c.document.getElementsByTag("iframe"),l;h&&a.is("iframe")&&(l=a.$.contentWindow.document.body,l.className=(a.getAttribute("lj-class")||"")+" lj-selected","LJPollLink"==a.getAttribute("lj-cmd")&&a.setStyle("height", l.scrollHeight+"px"));for(var e=0,u=i.count();e<u;e++)h=i.getItem(e),h.$!=a.$&&(l=h.$.contentWindow.document.body,l.className=h.getAttribute("lj-class")||"","LJPollLink"==h.getAttribute("lj-cmd")&&"lj-poll"==l.className&&h.removeAttribute("style"))}do i=a.getAttribute("lj-cmd"),!i&&1==a.type&&(h=a.getParent(),a.is("img")&&h.getParent()&&!h.getParent().hasAttribute("lj:user")?(i="image",a.setAttribute("lj-cmd",i)):a.is("a")&&!h.hasAttribute("lj:user")&&(i="LJLink",a.setAttribute("lj-cmd",i))),i&&k.hasOwnProperty(i)&& (d&&(k[i].node=a,c.getCommand(i).setState(CKEDITOR.TRISTATE_ON)),(b||(b={}))[i]={content:k[i].html,node:a});while(a=a.getParent());if(d)for(f in k)if(k.hasOwnProperty(f)&&(!b||!b.hasOwnProperty(f)))delete k[f].node,c.getCommand(f).setState(CKEDITOR.TRISTATE_OFF);b?CKEDITOR.note.show(b):CKEDITOR.note.hide()}}function f(a,b,h){var d,i=k[b].node;if(i){if(d=prompt(h.title,i.getAttribute("text")||h.text))d==h.text?i.removeAttribute("text"):i.setAttribute("text",d)}else{if(d=prompt(h.title,h.text)){var i= new CKEDITOR.dom.selection(c.document),f=i.getRanges(),l=new CKEDITOR.dom.element("iframe",c.document),e=new CKEDITOR.dom.element("iframe",c.document);l.setAttribute("lj-cmd",b);l.setAttribute("lj-class",a+" "+a+"-open");l.setAttribute("class",a+"-wrap");l.setAttribute("frameBorder",0);l.setAttribute("allowTransparency","true");d!=h.text&&l.setAttribute("text",d);e.setAttribute("lj-class",a+" "+a+"-close");e.setAttribute("class",a+"-wrap");e.setAttribute("frameBorder",0);e.setAttribute("allowTransparency", "true");a=f[0];if(!0===a.collapsed)c.insertElement(e),e.insertBeforeMe(l),e.insertBeforeMe(new CKEDITOR.dom.element("br",c.document)),e.insertBeforeMe(new CKEDITOR.dom.element("br",c.document));else{i.lock();a.getTouchedStartNode();b=new CKEDITOR.dom.documentFragment(c.document);b.append(l);h=0;for(d=f.length;h<d;h++)b.append(f[h].extractContents());c.insertElement(e);e.insertBeforeMe(b);a.setStartAfter(l);a.setEndBefore(e);i.unlock()}l.insertBeforeMe(new CKEDITOR.dom.element("br",c.document));(new CKEDITOR.dom.element("br", c.document)).insertAfter(e);f.length=1;i.selectRanges(f)}CKEDITOR.note&&CKEDITOR.note.hide(!0)}}(function(){function a(b){return"/>"==b.slice(-2)?b:b.slice(0,-1)+"/>"}function b(a){a=new Poll(a);return'<iframe class="lj-poll-wrap" lj-class="lj-poll" frameborder="0" lj-cmd="LJPollLink" allowTransparency="true" lj-data="'+a.outputLJtags()+'" lj-content="'+a.outputHTML()+'"></iframe>'}function d(a,b,c){return'<iframe class="lj-embed-wrap" lj-class="lj-embed" frameborder="0" allowTransparency="true" lj-data="'+ encodeURIComponent(c)+'"'+b+"></iframe>"}function e(a,b,c,d){return b+c.replace(/\n/g,"")+d}c.dataProcessor.toHtml=function(c,f){c=c.replace(/<lj [^>]*?>/gi,a).replace(/<lj-map [^>]*?>/gi,a).replace(/<lj-template[^>]*?>/gi,a).replace(/(<lj-cut[^>]*?)\/>/gi,"$1>").replace(/<((?!br)[^\s>]+)([^>]*?)\/>/gi,"<$1$2></$1>").replace(/<lj-poll.*?>[\s\S]*?<\/lj-poll>/gi,b).replace(/<lj-embed(.*?)>([\s\S]*?)<\/lj-embed>/gi,d);$("event_format").checked||(c=c.replace(/(<lj-raw.*?>)([\s\S]*?)(<\/lj-raw>)/gi,e), window.switchedRteOn||(c=c.replace(/\n/g,"<br />")));c=CKEDITOR.htmlDataProcessor.prototype.toHtml.call(this,c,f);CKEDITOR.env.ie&&(c='<xml:namespace ns="livejournal" prefix="lj" />'+c);return c}})();c.dataProcessor.toDataFormat=function(a,b){a=CKEDITOR.htmlDataProcessor.prototype.toDataFormat.call(this,a,b);$("event_format").checked||(a=a.replace(/<br\s*\/>/gi,"\n"));return a.replace(/\t/g," ")};c.dataProcessor.writer.indentationChars="";c.dataProcessor.writer.lineBreakChars="";c.on("selectionChange", e);c.on("doubleclick",g);c.on("afterCommandExec",d);c.on("dialogHide",d);c.on("dataReady",function(){CKEDITOR.note||r(c);CKEDITOR.env.ie&&(c.document.getBody().on("dragend",d),c.document.getBody().on("paste",function(){setTimeout(d,0)}));c.document.on("click",e);c.document.on("mouseout",CKEDITOR.note.hide);c.document.on("mouseover",e);c.document.getBody().on("keyup",a);d()});(function(){var a=top.Site.siteroot+"/tools/endpoints/ljuser.bml";c.addCommand("LJUserLink",{exec:function(b){var d="",b=new CKEDITOR.dom.selection(b.document), e;k.LJUserLink.node?(CKEDITOR.note&&CKEDITOR.note.hide(!0),e=k.LJUserLink.node.getElementsByTag("b").getItem(0).getText(),d=prompt(top.CKLang.UserPrompt,e)):2==b.getType()&&(d=b.getSelectedText());""==d&&(d=prompt(top.CKLang.UserPrompt,d));d&&e!=d&&parent.HTTPReq.getJSON({data:parent.HTTPReq.formEncoded({username:d}),method:"POST",url:a,onData:function(a){var b=d;a.error?alert(a.error):a.success&&(a.ljuser=a.ljuser.replace('<span class="useralias-value">*</span>',""),n[b]=a.ljuser,a=new CKEDITOR.dom.element.createFromHtml(a.ljuser), a.setAttribute("lj-cmd","LJUserLink"),LJUser?LJUser.$.parentNode.replaceChild(a.$,LJUser.$):c.insertElement(a))}})}});c.ui.addButton("LJUserLink",{label:top.CKLang.LJUser,command:"LJUserLink"})})();c.ui.addButton("image",{label:top.CKLang.LJImage_Title,command:"image"});c.addCommand("LJImage_beta",{exec:function(){InOb.handleInsertImageBeta("upload")},editorFocus:!1});c.ui.addButton("LJImage_beta",{label:top.CKLang.LJImage_BetaTitle,command:"LJImage_beta"});c.addCommand("LJLink",{exec:function(a){!p&& this.state==CKEDITOR.TRISTATE_ON?a.execCommand("unlink"):a.openDialog("link");CKEDITOR.note&&CKEDITOR.note.hide(!0)},editorFocus:!1});c.ui.addButton("LJLink",{label:c.lang.link.toolbar,command:"LJLink"});(function(){function a(b){if(b&&b.length&&window.switchedRteOn){var h=new CKEDITOR.dom.element("iframe",c.document);h.setAttribute("lj-data",encodeURIComponent(b));h.setAttribute("lj-class","lj-embed");h.setAttribute("class","lj-embed-wrap");h.setAttribute("frameBorder",0);h.setAttribute("allowTransparency", "true");c.insertElement(h);d()}}c.addCommand("LJEmbedLink",{exec:function(){top.LJ_IPPU.textPrompt(top.CKLang.LJEmbedPromptTitle,top.CKLang.LJEmbedPrompt,a,{width:"350px"})}});c.ui.addButton("LJEmbedLink",{label:top.CKLang.LJEmbed,command:"LJEmbedLink"})})();c.addCommand("LJCut",{exec:function(){f("lj-cut","LJCut",{title:top.CKLang.LJCut_PromptTitle,text:top.CKLang.LJCut_PromptText})},editorFocus:!1});c.ui.addButton("LJCut",{label:top.CKLang.LJCut_Title,command:"LJCut"});c.addCommand("LJSpoiler", {exec:function(){f("lj-spoiler","LJSpoiler",{title:top.CKLang.LJSpoiler_PromptTitle,text:top.CKLang.LJSpoiler_PromptText})},editorFocus:!1});c.ui.addButton("LJSpoiler",{label:top.CKLang.LJSpoiler_Title,command:"LJSpoiler"});(function(){function a(b,c){var c=void 0===c||c,d;if(k.LJLike.node)d=(d=b.getAttribute("lj-style"))?d.replace(/text-align:\s*(left|right|center)/i,"$1"):"left";else if(c)d=b.getComputedStyle("text-align");else{for(;!b.hasAttribute||!b.hasAttribute("align")&&!b.getStyle("text-align");){d= b.getParent();if(!d)break;b=d}d=b.getStyle("text-align")||b.getAttribute("align")||""}d&&(d=d.replace(/-moz-|-webkit-|start|auto/i,""));!d&&c&&(d="rtl"==b.getComputedStyle("direction")?"right":"left");return d}function b(d){if(!d.editor.readOnly){var e=d.editor.getCommand(this.name),d=d.data.element;e.state="LJLike"==(1==d.type&&d.hasAttribute("lj-cmd")&&d.getAttribute("lj-cmd"))?a(d,c.config.useComputedState)==this.value?CKEDITOR.TRISTATE_ON:CKEDITOR.TRISTATE_OFF:!d||1!=d.type||"body"==d.getName()|| "iframe"==d.getName()?CKEDITOR.TRISTATE_OFF:a(d,c.config.useComputedState)==this.value?CKEDITOR.TRISTATE_ON:CKEDITOR.TRISTATE_OFF;e.fire("state")}}function d(a,b,c){this.name=b;this.value=c;if(a=a.config.justifyClasses){switch(c){case "left":this.cssClassName=a[0];break;case "center":this.cssClassName=a[1];break;case "right":this.cssClassName=a[2]}this.cssClassRegex=RegExp("(?:^|\\s+)(?:"+a.join("|")+")(?=$|\\s)")}}d.prototype={exec:function(b){var c=b.getSelection(),d=b.config.enterMode;if(c){var e= c.createBookmarks();if(k.LJLike.node)k.LJLike.node.setAttribute("lj-style","text-align: "+this.value);else for(var h=c.getRanges(!0),f=this.cssClassName,i,j,g=b.config.useComputedState,g=void 0===g||g,m=h.length-1;0<=m;m--){i=h[m];if((j=i.getEnclosedNode())&&j.is("iframe"))return;i=i.createIterator();for(i.enlargeBr=d!=CKEDITOR.ENTER_BR;j=i.getNextParagraph(d==CKEDITOR.ENTER_P?"p":"div");){j.removeAttribute("align");j.removeStyle("text-align");var s=f&&(j.$.className=CKEDITOR.tools.ltrim(j.$.className.replace(this.cssClassRegex, ""))),q=this.state==CKEDITOR.TRISTATE_OFF&&(!g||a(j,!0)!=this.value);f?q?j.addClass(f):s||j.removeAttribute("class"):q&&j.setStyle("text-align",this.value)}}b.focus();b.forceNextSelectionCheck();c.selectBookmarks(e)}}};var e=new d(c,"LJJustifyLeft","left"),f=new d(c,"LJJustifyCenter","center"),j=new d(c,"LJJustifyRight","right");c.addCommand("LJJustifyLeft",e);c.addCommand("LJJustifyCenter",f);c.addCommand("LJJustifyRight",j);c.ui.addButton("LJJustifyLeft",{label:c.lang.justify.left,command:"LJJustifyLeft"}); c.ui.addButton("LJJustifyCenter",{label:c.lang.justify.center,command:"LJJustifyCenter"});c.ui.addButton("LJJustifyRight",{label:c.lang.justify.right,command:"LJJustifyRight"});c.on("selectionChange",CKEDITOR.tools.bind(b,e));c.on("selectionChange",CKEDITOR.tools.bind(b,j));c.on("selectionChange",CKEDITOR.tools.bind(b,f));c.on("dirChanged",function(a){var b=a.editor,c=new CKEDITOR.dom.range(b.document);c.setStartBefore(a.data.node);c.setEndAfter(a.data.node);for(var d=new CKEDITOR.dom.walker(c),e;e= d.next();)if(e.type==CKEDITOR.NODE_ELEMENT){var h=b.config.justifyClasses;if(!e.equals(a.data.node)&&e.getDirection())c.setStartAfter(e),d=new CKEDITOR.dom.walker(c);else switch(h&&(e.hasClass(h[0])?(e.removeClass(h[0]),e.addClass(h[2])):e.hasClass(h[2])&&(e.removeClass(h[2]),e.addClass(h[0]))),e.getStyle("text-align")){case "left":e.setStyle("text-align","right");break;case "right":e.setStyle("text-align","left")}}})})();if(top.canmakepoll){var j;CKEDITOR.dialog.add("LJPollDialog",function(){var a= 0,b,e,f,i=function(){this.removeListener&&this.removeListener("load",i);a&&b?(j=new Poll(k.LJPollLink.node&&decodeURIComponent(k.LJPollLink.node.getAttribute("lj-data")),e.document,f.document,e.Questions),e.ready(j),f.ready(j),b.style.display="block",CKEDITOR.note&&CKEDITOR.note.hide(!0)):a++},g=[new CKEDITOR.ui.button({type:"button",id:"LJPoll_Ok",label:c.lang.common.ok,onClick:function(a){a.data.dialog.hide();var b=new Poll(j,e.document,f.document,e.Questions),a=b.outputHTML(),b=b.outputLJtags(); if(0<a.length){var i=k.LJPollLink.node;i?(i.setAttribute("lj-content",a),i.setAttribute("lj-data",b),i.removeAttribute("style"),i.$.contentWindow.document.body.className="lj-poll"):(i=new CKEDITOR.dom.element("iframe",c.document),i.setAttribute("lj-content",a),i.setAttribute("lj-cmd","LJPollLink"),i.setAttribute("lj-data",b),i.setAttribute("lj-class","lj-poll"),i.setAttribute("class","lj-poll-wrap"),i.setAttribute("frameBorder",0),i.setAttribute("allowTransparency","true"),c.insertElement(i));k.LJPollLink.node= null;d()}}}),CKEDITOR.dialog.cancelButton];CKEDITOR.env.mac&&g.reverse();return{title:top.CKLang.Poll_PollWizardTitle,width:420,height:270,resizable:!1,onShow:function(){a&&(j=new Poll(k.LJPollLink.node&&unescape(k.LJPollLink.node.getAttribute("data")),e.document,f.document,e.Questions),e.ready(j),f.ready(j))},contents:[{id:"LJPoll_Setup",label:"Setup",padding:0,elements:[{type:"html",html:'<iframe src="/tools/ck_poll_setup.bml" allowTransparency="true" frameborder="0" style="width:100%; height:320px;"></iframe>', onShow:function(a){b||((b=document.getElementById(a.sender.getButton("LJPoll_Ok").domId).parentNode).style.display="none");a=this.getElement("iframe");f=a.$.contentWindow;if(f.ready)i();else a.on("load",i)}}]},{id:"LJPoll_Questions",label:"Questions",padding:0,elements:[{type:"html",html:'<iframe src="/tools/ck_poll_questions.bml" allowTransparency="true" frameborder="0" style="width:100%; height:320px;"></iframe>',onShow:function(){var a=this.getElement("iframe");e=a.$.contentWindow;if(e.ready)i(); else a.on("load",i)}}]}],buttons:g}});c.addCommand("LJPollLink",new CKEDITOR.dialogCommand("LJPollDialog"))}else c.addCommand("LJPollLink",{exec:function(){CKEDITOR.note&&CKEDITOR.note.show(top.CKLang.Poll_AccountLevelNotice,null,null,!0)}}),c.getCommand("LJPollLink").setState(CKEDITOR.TRISTATE_DISABLED);c.ui.addButton("LJPollLink",{label:top.CKLang.Poll_Title,command:"LJPollLink"});(function(){function a(){c.getCommand("LJLike")==CKEDITOR.TRISTATE_OFF&&(this.$.checked?e++:e--,f.getButton("LJLike_Ok").getElement()[0== e?"addClass":"removeClass"]("btn-disabled"))}var b=m.length,d='<div class="cke-dialog-likes"><ul class="cke-dialog-likes-list">',e=0,f,j;m.defaultButtons=[];for(var g=0;g<b;g++){var n=m[g];m[n.id]=m[n.abbr]=n;m.defaultButtons.push(n.id);d+=n.htmlOpt}d+='</ul><p class="cke-dialog-likes-faq">'+window.faqLink+"</p></div>";CKEDITOR.dialog.add("LJLikeDialog",function(){var g=[new CKEDITOR.ui.button({type:"button",id:"LJLike_Ok",label:c.lang.common.ok,onClick:function(){var a=[],d='<span class="lj-like-wrapper">', e=k.LJLike.node;if(f.getButton("LJLike_Ok").getElement().hasClass("btn-disabled"))return!1;for(var h=0;h<b;h++){var j=m[h],g=document.getElementById("like-"+j.abbr),l=e&&e.getAttribute("buttons");if(g&&g.checked||l&&!j.htmlOpt&&(l.indexOf(j.abbr)+1||l.indexOf(j.id)+1))a.push(j.id),d+=j.html}d+="</span>";a.length?e?(k.LJLike.node.setAttribute("buttons",a.join(",")),k.LJLike.node.setAttribute("lj-content",encodeURIComponent(d))):(e=new CKEDITOR.dom.element("iframe",c.document),e.setAttribute("lj-class", "lj-like"),e.setAttribute("class","lj-like-wrap"),e.setAttribute("buttons",a.join(",")),e.setAttribute("lj-content",encodeURIComponent(d)),e.setAttribute("lj-cmd","LJLike"),e.setAttribute("frameBorder",0),e.setAttribute("allowTransparency","true"),c.insertElement(e)):e&&k.LJLike.node.remove();f.hide()}}),CKEDITOR.dialog.cancelButton];CKEDITOR.env.mac&&g.reverse();return{title:top.CKLang.LJLike_name,width:145,height:window.isSupUser?180:145,resizable:!1,contents:[{id:"LJLike_Options",elements:[{type:"html", html:d}]}],onShow:function(){var a=c.getCommand("LJLike"),d=e=0,a=a.state==CKEDITOR.TRISTATE_ON,h=k.LJLike.node&&k.LJLike.node.getAttribute("buttons");for(CKEDITOR.note&&CKEDITOR.note.hide(!0);d<b;d++){var j=h?!!(h.indexOf(m[d].abbr)+1||h.indexOf(m[d].id)+1):!0,g=document.getElementById("like-"+m[d].abbr);g&&(j&&!a&&e++,g.checked=j)}0<e&&f.getButton("LJLike_Ok").getElement().removeClass("btn-disabled")},onLoad:function(){f=this;j=f.parts.contents.getElementsByTag("input");for(var d=0;d<b;d++){var c= j.getItem(d);c&&c.on("click",a)}},buttons:g}});c.addCommand("LJLike",new CKEDITOR.dialogCommand("LJLikeDialog"));c.ui.addButton("LJLike",{label:top.CKLang.LJLike_name,command:"LJLike"})})()},afterInit:function(c){function g(a,b,d){var c=new CKEDITOR.htmlParser.element("iframe");c.attributes["lj-class"]=b+" "+b+"-open";c.attributes["class"]=b+"-wrap";c.attributes["lj-cmd"]=d;c.attributes.frameBorder=0;c.attributes.allowTransparency="true";a.attributes.hasOwnProperty("text")&&(c.attributes.text=a.attributes.text); a.children.unshift(c);d=new CKEDITOR.htmlParser.element("iframe");d.attributes["lj-class"]=b+" "+b+"-close";d.attributes["class"]=b+"-wrap";d.attributes.frameBorder=0;d.attributes.allowTransparency="true";a.children.push(d);delete a.name}var k=c.dataProcessor;k.dataFilter.addRules({elements:{"lj-like":function(a){var b=[],d=new CKEDITOR.htmlParser.element("iframe");d.attributes["lj-class"]="lj-like";d.attributes["class"]="lj-like-wrap";a.attributes.hasOwnProperty("style")&&(d.attributes["lj-style"]= a.attributes.style);d.attributes["lj-cmd"]="LJLike";d.attributes["lj-content"]='<span class="lj-like-wrapper">';d.attributes.frameBorder=0;d.attributes.allowTransparency="true";for(var a=a.attributes.buttons&&a.attributes.buttons.split(",")||m.defaultButtons,c=a.length,f=0;f<c;f++){var j=a[f].replace(/^\s*([a-z]{2,})\s*$/i,"$1"),g=m[j];g&&(d.attributes["lj-content"]+=encodeURIComponent(g.html),b.push(j))}d.attributes["lj-content"]+="</span>";d.attributes.buttons=b.join(",");return d},lj:function(){function a(b){for(var d= c.document.getElementsByTag("lj"),e=0,f=d.count();e<f;e++){var j=d.getItem(e),g=j.getAttribute("user"),k=j.getAttribute("title");if(b==(k?g+":"+k:g))g=new CKEDITOR.dom.element.createFromHtml(n[b],c.document),g.setAttribute("lj-cmd","LJUserLink"),j.insertBeforeMe(g),j.remove()}c.removeListener("dataReady",a)}return function(b){var d=b.attributes.user;if(d&&d.length){var e=(b=b.attributes.title)?d+":"+b:d;if(n.hasOwnProperty(e))return b=(new CKEDITOR.htmlParser.fragment.fromHtml(n[e])).children[0], b.attributes["lj-cmd"]="LJUserLink",b;var f={username:d};b&&(f.usertitle=b);HTTPReq.getJSON({data:HTTPReq.formEncoded(f),method:"POST",url:Site.siteroot+"/tools/endpoints/ljuser.bml",onError:function(a){alert(a+' "'+d+'"')},onData:function(b){if(b.error)return alert(b.error+' "'+d+'"');if(b.success)if(n[e]=b.ljuser,b.ljuser=b.ljuser.replace('<span class="useralias-value">*</span>',""),c.document)a(e);else c.on("dataReady",function(){a(e)})}})}}}(),"lj-map":function(a){var b=new CKEDITOR.htmlParser.element("iframe"), d="",c="",f=Number(a.attributes.width),g=Number(a.attributes.height);isNaN(f)||(d+="width:"+f+"px;",c+="width:"+(f-2)+"px;");isNaN(g)||(d+="height:"+g+"px;",c+="height:"+(g-2)+"px;");d.length&&(b.attributes.style=d,b.attributes["lj-style"]=c);b.attributes["lj-url"]=a.attributes.url?encodeURIComponent(a.attributes.url):"";b.attributes["lj-class"]="lj-map";b.attributes["class"]="lj-map-wrap";b.attributes["lj-content"]='<p class="lj-map">map</p>';b.attributes.frameBorder=0;b.attributes.allowTransparency= "true";return b},"lj-repost":function(a){var b=new CKEDITOR.htmlParser.element("input");b.attributes.type="button";b.attributes.value=a.attributes&&a.attributes.button||top.CKLang.LJRepost_Value;b.attributes["class"]="lj-repost";return b},"lj-raw":function(a){a.name="lj:raw"},"lj-wishlist":function(a){a.name="lj:wishlist"},"lj-template":function(a){a.name="lj:template";a.children.length=0},"lj-cut":function(a){g(a,"lj-cut","LJCut")},"lj-spoiler":function(a){g(a,"lj-spoiler","LJSpoiler")},iframe:function(a){if(a.attributes["lj-class"]&& 1==a.attributes["lj-class"].indexOf("lj-")+1)return a;var b=new CKEDITOR.htmlParser.element("iframe"),c="",e="",f=Number(a.attributes.width),g=Number(a.attributes.height);isNaN(f)||(c+="width:"+f+"px;",e+="width:"+(f-2)+"px;");isNaN(g)||(c+="height:"+g+"px;",e+="height:"+(g-2)+"px;");c.length&&(b.attributes.style=c,b.attributes["lj-style"]=e);b.attributes["lj-url"]=a.attributes.src?encodeURIComponent(a.attributes.src):"";b.attributes["lj-class"]="lj-iframe";b.attributes["class"]="lj-iframe-wrap"; b.attributes["lj-content"]='<p class="lj-iframe">iframe</p>';b.attributes.frameBorder=0;b.attributes.allowTransparency="true";return b},a:function(a){a.parent.attributes&&!a.parent.attributes["lj:user"]&&(a.attributes["lj-cmd"]="LJLink")},img:function(a){var b=a.parent&&a.parent.parent;if(!b||!b.attributes||!b.attributes["lj:user"])a.attributes["lj-cmd"]="image"},div:function(a){"lj-cut"==a.attributes["class"]&&g(a,"lj-cut","LJCut")}}},5);k.htmlFilter.addRules({elements:{iframe:function(a){var b= a,c=!1,e=/lj-[a-z]+/i.exec(a.attributes["lj-class"]);if(e)e=e[0];else return a;switch(e){case "lj-like":b=new CKEDITOR.htmlParser.element("lj-like");b.attributes.buttons=a.attributes.buttons;a.attributes.hasOwnProperty("lj-style")&&(b.attributes.style=a.attributes["lj-style"]);b.isEmpty=!0;b.isOptionalClose=!0;break;case "lj-embed":b=new CKEDITOR.htmlParser.element("lj-embed");b.attributes.id=a.attributes.id;a.attributes.hasOwnProperty("source_user")&&(b.attributes.source_user=a.attributes.source_user); b.children=(new CKEDITOR.htmlParser.fragment.fromHtml(decodeURIComponent(a.attributes["lj-data"]))).children;b.isOptionalClose=!0;break;case "lj-map":b=new CKEDITOR.htmlParser.element("lj-map");b.attributes.url=decodeURIComponent(a.attributes["lj-url"]);a.attributes.style&&(a.attributes.style+";").replace(/([a-z-]+):(.*?);/gi,function(a,c,d){b.attributes[c.toLowerCase()]=parseInt(d)});b.isOptionalClose=b.isEmpty=!0;break;case "lj-iframe":b=new CKEDITOR.htmlParser.element("iframe");b.attributes.src= decodeURIComponent(a.attributes["lj-url"]);a.attributes.style&&(a.attributes.style+";").replace(/([a-z-]+):(.*?);/gi,function(a,c,d){b.attributes[c.toLowerCase()]=parseInt(d)});b.attributes.frameBorder=0;break;case "lj-poll":b=(new CKEDITOR.htmlParser.fragment.fromHtml(decodeURIComponent(a.attributes["lj-data"]))).children[0];break;case "lj-spoiler":c=!0;case "lj-cut":if(a.attributes["lj-class"].indexOf(e+"-open")+1){var f=a.next,g=0,b=new CKEDITOR.htmlParser.element(e);a.attributes.hasOwnProperty("text")&& (b.attributes.text=a.attributes.text);for(;f;){if("iframe"==f.name)if(a=f.attributes["lj-class"],a.indexOf(e+"-close")+1)if(c&&g)g--;else{b.next=f;break}else if(a.indexOf(e+"-open")+1)if(c)g++;else{b.next=f;break}f.parent.children.remove(f);b.add(f);a=f.next;f.next=null;f=a}}else b=!1;break;default:a.children.length||(b=!1)}return b},span:function(a){var b=a.attributes["lj:user"];if(b){var c=new CKEDITOR.htmlParser.element("lj");c.attributes.user=b;try{var e=a.children[1].children[0].children[0].value}catch(f){return!1}e&& e!=b&&(c.attributes.title=e);c.isOptionalClose=c.isEmpty=!0;return c}if("display: none;"==a.attributes.style||!a.children.length)return!1},input:function(a){if("lj-repost"==a.attributes["class"]){var b=new CKEDITOR.htmlParser.element("lj-repost");a.attributes.value!=top.CKLang.LJRepost_Value&&(b.attributes.button=a.attributes.value);b.isOptionalClose=b.isEmpty=!0;return b}},div:function(a){if(!a.children.length)return!1},"lj:template":function(a){a.name="lj-template";a.isOptionalClose=a.isEmpty=!0}, "lj:raw":function(a){a.name="lj-raw"},"lj:wishlist":function(a){a.name="lj-wishlist"}},attributes:{"lj-cmd":function(){return!1},contenteditable:function(){return!1}}})},requires:["fakeobjects","domiterator"]})})();