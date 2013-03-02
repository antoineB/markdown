#lang rackjure

(require xml (prefix-in h: html))

(provide
 (contract-out [read-markdown (-> xexpr?)]
               [current-allow-html? (parameter/c boolean?)]))

(module+ test
  (require rackunit))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Allow literal HTML in the markdown file to be passed through to the
;; output? If #f then the HTML is escaped.
(define current-allow-html? (make-parameter #t))

;; Returns (listof xexpr?) that may be spliced into a 'body element --
;; i.e. `(html () (head () (body () ,@(read-markdown))))
(define (read-markdown) ;; -> (listof xexpr?)
  (parameterize ([current-refs (make-hash)])
    (~> (read-blocks)
        resolve-refs
        remove-br-before-blocks)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; link refs

(define current-refs (make-parameter (make-hash)))

(define (resolve-refs xs) ;; (listof xexpr?) -> (listof xexpr?)
  ;; Walk the xexprs looking for 'a elements whose 'href attribute is
  ;; symbol?, and replace with hash value. Same for 'img elements'
  ;; 'src attributes.
  (define (get-attr alist k)
    (define v (assoc k alist))
    (and v (cadr v)))
  (define (set-attr alist k v)
    (dict-set alist k (list v))) ;put in list b/c dict-set on list not alist
  (define (resolve attrs name body)
    (define uri (get-attr attrs name))
    (cond [(and uri (symbol? uri))
           `(a ,(set-attr attrs name (get-ref uri)) ,@body)]
          [else `(a ,attrs ,@body)]))
  (define (do-xpr xs)
    (match xs
      [(list tag (list attrs ...) body ...)
       (match tag
         ['a   (resolve attrs 'href body)]
         ['img (resolve attrs 'src body)]
         [else `(,tag ,attrs ,@(map do-xpr body))])]
      [(list tag body ...) `(,tag ,@(map do-xpr body))]
      [else xs]))
  (for/list ([x xs])
    (do-xpr x)))

(define (add-ref! name uri) ;; symbol? string? -> any
  ;;(printf "add-ref! ~v ~v\n" name uri)
  (hash-set! (current-refs) name uri))

(define (get-ref name)
  (or (dict-ref (current-refs) name #f)
      (begin (log-warning "Linkref '~a' not resolved.\n" name) "")))

(module+ test
  (check-equal? (parameterize ([current-refs (make-hash)])
                  (add-ref! 'foo "bar")
                  (resolve-refs '((a ([href foo]) "foo"))))
                '((a ((href "bar")) "foo"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; block level

(define (read-blocks)
  (let loop ([xs '()])
    (define x (block-level))
    (cond [x (loop (append xs x))]
          [else xs])))

(define (remove-br-before-blocks xs)
  (for/list ([this (in-list xs)]
             [next (in-list (append (drop xs 1) (list "")))]) ;bit slow way
    (match this
      [(list 'br) (match next
                    [(list (or 'blockquote 'pre) _ ...) ""]
                    [else this])]
      [else this])))

(define (block-level) ;; -> (or/c #f list?)
  (or (heading)
      (code-block-indent)
      (code-block-backtick)
      (blockquote)
      (hr-block) ;; must go BEFORE list block
      (list-block)
      (linkref-block)
      (other)))

(define (hr-block)
  (match (try #px"^(?:[*-] ?){3,}\n+")
    [(list _) `((hr))]
    [else #f]))

;; Lists and sublists. Uff da.
;;
;; 1. A ul is one or more li.
;;
;; 2. An li is a marker (e.g. "-"), followed by li-contents, followed
;; by another marker at the same level (or the end).
;;
;; 3. li-contents is list of either:
;;
;; - Some text (which should be run through intra-block processing).
;;
;; - Another ul (indicated by a marker (e.g. "-")) with more
;; indentation). Recursively do 1.

(define ulm "[*+-]")
(define olm "\\d+[.]")
(define marker (str "(?:" ulm "|" olm ")"))

;; Look for an entire list, including any sublists.
(define (list-block)
  (define px (pregexp (str "^"
                           "[ ]{0,3}" marker ".+?" "\n{2,}" "(?=\\S)"
                           ;; not another one
                           "(?![ \t]*" marker "[ \t]+)"
                           )))
  (match (try px)
    [(list text) (list (do-list text))]
    [(var x) #f]))

;; Process an entire list level, and recursively process any
;; sub-lists.
(define (do-list s)
  (define xs
    (~>>
     ;; If string ends in > 1 \n, set it to just 1. See below.
     (regexp-replace #px"\n{2,}$" s "\n")
     ;; Split the string into list items.
     (regexp-split (pregexp (str "(?<=^|\n)" marker "\\s+")))
     ;; Remove the "" left by regexp-split
     (filter (negate (curry equal? "")))))
  (define first-marker (match s
                         [(pregexp (str "^(" marker ")") (list _ x)) x]))
  (define tag
    (match first-marker
      [(pregexp ulm) 'ul]
      [else 'ol]))
  `(,tag
    ,@(for/list ([x xs])
        (match x
          ;; List item with a sublist?
          [(pregexp (str "^(.+?)" "(?<=\n)" "(\\s+ " marker ".+)$")
                    (list _ text sublist))
           `(li ,@(intra-block text) ,(do-list (outdent sublist)))]
          [else
           (match x
             ;; If the item ends in 2+ \n, nest the text in a
             ;; 'p element to get a space between it and the
             ;; next item. (We stripped \n\n from the very last
             ;; item, above.)
             [(pregexp "^(.*)\n{2}$" (list _ text))
              `(li (p ,@(intra-block text)))]
             ;; Otherwise just goes directly in the 'li
             ;; element.
             [(pregexp "^(.*)\n*$" (list _ text))
              `(li ,@(intra-block text))])]))))

(module+ test
  (check-equal? (do-list (str #:sep "\n"
                              "- Bullet 1"
                              ""
                              "- Bullet 2"
                              "  - Bullet 2a"
                              "  - Bullet 2b"
                              "    - Bullet 2bi"
                              "- Bullet 3"
                              "  - Bullet 3a"
                              "- Bullet 4"
                              "  continued"
                              "- Bullet 5"
                              ))
                '(ul (li (p "Bullet 1"))
                     (li
                      "Bullet 2 "
                      (ul (li "Bullet 2a ")
                          (li "Bullet 2b "
                              (ul (li "Bullet 2bi ")))))
                     (li "Bullet 3 "
                         (ul (li "Bullet 3a ")))
                     (li "Bullet 4   continued ")
                     (li "Bullet 5")))

  (check-equal? (do-list (str #:sep "\n"
                              "1. One"
                              "  1. One / One"
                              "  2. One / Two"
                              "2. Two"
                              "  1. Two / One"
                              "  2. Two / Two"
                              ""))
                '(ol
                  (li "One " (ol (li "One / One ")
                                  (li "One / Two ")))
                  (li "Two " (ol (li "Two / One ")
                                  (li "Two / Two "))))))

(define (outdent s)
  (match s
    [(pregexp "^(\\s*)(.*)$" (list _ lead rest))
     (regexp-replace* (pregexp (str "\n" lead)) rest "\n")]))

(module+ test
  (check-equal?
   (outdent (str #:sep "\n"
                 "  Indent"
                 "  Indent"
                 "    More"
                 ""
                 "    More"
                 "  Indent"
                 "  Indent"))
   (str #:sep "\n"
        "Indent"
        "Indent"
        "  More"
        ""
        "  More"
        "Indent"
        "Indent")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (heading) ;; -> (or/c #f list?)
  (match (try #px"^\\s*(#+) ([^\n]+)\n\n")
    [(list _ pounds text)
     (define tag (~> (str "h" (string-length pounds))
                     string->symbol))
     `((,tag ,@(~> text intra-block)))]
    [else #f]))
              
(define (code-block-indent) ;; -> (or/c #f list?)
  (match (try #px"^(    [^\n]*\n)+\n")
    [(list code _)
     `((pre (code ,(~> code
                       (nuke-all #px"^    ")
                       (nuke-all #px"\n    " "\n")
                       (nuke-all #px"\n+$")))))]
    [else #f]))

(define (code-block-backtick) ;; -> (or/c #f list?)
  (match (try #px"^```(.*?)\n(.*?\n)```\n")
    [(list _ lang code)
     `((pre (code ([class ,(str "brush: '" lang "';")])
                  ,(~> code
                       (nuke-all #px"\n+$")))))]
    [else #f]))

(define (blockquote) ;; -> (or/c #f list?)
  (match (try #px"^> (.+?\n\n)+?")
    [(list _ bq)
     `((blockquote (p ,@(~> bq 
                            (nuke-all #px"\n+$" "")
                            (nuke-all #px"\n> " " ")
                            (nuke-all #px"\n" " ")
                            intra-block))))]
    [else #f]))

(define (linkref-block)
  (match (try #px"^\\[(.+?)\\]:\\s*(\\S+)\\s*\"(.+?)\"\n+")
    [(list _ refname uri title)
     (add-ref! (string->symbol refname) uri)
     `((p (em ,title) ": " (a ([href ,uri]) ,uri)))]
    [else #f]))

(define (other) ;; -> (or/c #f list?)
  (match (try #px"^(.+?)\n\n")
    [(list _ text)
     `((p ,@(intra-block text)))]
    [else
     (let ([s (read-line (current-input-port) 'any)])
       (and (not (eof-object? s))
            `(,@(intra-block (str s "\n")))))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; intra-block

(define (intra-block s) ;; s -> (listof xexpr?)
  ;; Look for formatting within a block
  (~> s
      list
      code ;; before everything
      space&space&newline->br
      newlines->spaces
      html
      image
      link
      auto-link
      bold
      italic
      remove-br-before-blocks
      ))

(module+ test
  (check-equal? (intra-block "The expression `2 * foo_bar`")
                '("The expression " (code ([class "inline-code"])
                                          "2 * foo_bar"))))

;; `replace` is the workhorse for intra-block matching. It's in the
;; same spirit as regexep-replace*, but instead of just strings, it
;; deals with lists of xexprs (i.e. string or list).  It looks for
;; patterns in anything that is still a string?, and possibly breaks
;; the string into an xexpr?.  Subsequent calls to `replace` operate
;; only on elements that remained string?s.
;;
;; Given a (listof xexpr?) and a regexp, runs `regexp-match*` on each
;; xexpr that is a string?.  For each match that succeeds, calls `f`
;; with the results, and replaces the string with what `f` returns.
;; Uses `regexp-match` with #:gap-select? #t, so taht non-matches are
;; also returned. Instead of passing those to `f`, it simply keeps
;; them (unless they are "", in which case they're deleted).
(define (replace xs px f)
  (append*
   (map (lambda (x)
          (cond [(string? x)
                 (filter-map
                  values
                  (for/list ([x (in-list (regexp-match* px x
                                                        #:match-select values
                                                        #:gap-select? #t))])
                    (match x
                      [(? list? x) (apply f x)]
                      ["" #f]
                      [else x])))]
                [else (list x)]))
        xs)))

(define (html xs)
  (define (elements->element xs)
    (make-element #f #f '*root '() xs))
  (cond [(current-allow-html?)
         ;; We want to splice in the xexprs, not nest them in some
         ;; dummy parent. That's the reason for the extra level using
         ;; `box`, followed by the `list`-ing of non-boxed elements,
         ;; and finally the append*.
         (~>>
          (replace xs #px"<.+?>.*</\\S+?>"
                   ;; Although using a regexp to identify HTML text, we
                   ;; let read-html-as-xml do the real work oarsing it:
                   (lambda (x)
                     (box (parameterize ([permissive-xexprs #t])
                            (~> (open-input-string x)
                                h:read-html-as-xml
                                elements->element
                                xml->xexpr
                                cddr)))))
          (map (lambda (x)
                 (cond [(box? x) (unbox x)]
                       [else (list x)])))
          (append*))]
        [else xs])) ;; xexpr->string automatically escapes string xexprs

(module+ test
  (check-equal?
   (html '("Here is a <span class='foo'>text</span> element."))
   '("Here is a " (span ((class "foo")) "text") " element."))
  ;; Confirm it works fine with \n in middle of <tag>
  (check-equal?
   (html '("<span\n style='font-weight:bold;'>span</span>"))
   '((span ((style "font-weight:bold;")) "span")))
  )

(define (space&space&newline->br xs)
  (replace xs #px"  \n" (lambda (_) `(br))))

(define (newlines->spaces xs)
  (for/list ([x (in-list xs)])
    (cond [(string? x) (regexp-replace* #px"\n" x " ")]
          [else x])))

(define (image xs)
  (~> xs
      (replace #px"!\\[(.*?)\\]\\(([^ ]+)(\\s+\"(.+?)\"\\s*)?\\)"
           (lambda (_ alt src __ title)
             `(img ([alt ,alt][src ,src][title ,title]))))
      (replace #px"!\\[(.*?)\\]\\[([^ ]+)(\\s+\"(.+?)\"\\s*)?\\]"
           (lambda (_ alt src __ title)
             `(img ([alt ,alt][src ,(string->symbol src)][title ,title]))))))

(define (link xs)
  (~> xs
      (replace #px"\\[(.*?)\\]\\((.+?)\\)"
               (lambda (_ text href)
                 `(a ([href ,href]) ,text)))
      (replace #px"\\[(.*?)\\]\\[(.+?)\\]"
               (lambda (_ text href)
                 `(a ([href ,(string->symbol href)]) ,text)))))

(define (auto-link xs)
  (define (a _ uri)
    `(a ([href ,uri]) ,uri))
  (~> xs
      (replace #px"<(http.+?)>" a)
      (replace #px"<(www\\..+?)>" a)
      (replace #px"<([^@]+?@[^@]+?)>"
               (lambda (_ email) `(a ([href ,(str "mailto:" email)])
                                ,email)))
      (replace #px"<(.+\\.(?:com|net|org).*)>" a)))

(module+ test
  (check-equal?
   (auto-link '("<http://www.google.com/path/to/thing>"))
   '((a ((href "http://www.google.com/path/to/thing")) "http://www.google.com/path/to/thing")))
  (check-equal?
   (auto-link '("<www.google.com/path/to/thing>"))
   '((a ((href "www.google.com/path/to/thing")) "www.google.com/path/to/thing")))
  (check-equal?
   (auto-link '("<google.com/path/to/thing>"))
   '((a ((href "google.com/path/to/thing")) "google.com/path/to/thing")))
  (check-equal? (auto-link '("<foo@bar.com>"))
                '((a ((href "mailto:foo@bar.com")) "foo@bar.com"))))

(define (code xs)
  (define (code-xexpr _ x) `(code ([class "inline-code"]) ,x))
  (~> xs
      (replace #px"`` ?(.+?) ?``" code-xexpr)
      (replace #px"`(.+?)`" code-xexpr)))

(module+ test
  ;; See http://daringfireball.net/projects/markdown/syntax#code
  (check-equal? (code '("This is some `inline code` here"))
                '("This is some "
                  (code ([class "inline-code"]) "inline code")
                  " here"))
  (check-equal? (code '(" `` ` `` "))
                '(" " (code ([class "inline-code"]) "`") " "))
  (check-equal? (code '(" `` `foo` ``"))
                '(" " (code ([class "inline-code"]) "`foo`")))
  (check-equal? (code '("``There is a literal backtick (`) here.``"))
                '((code ([class "inline-code"])
                        "There is a literal backtick (`) here."))))

;; NOTE: Tricky part here is that `_` is considered a \w word char but
;; `*` is not. Therefore using \b in pregexp works for `_` but not for
;; `*`. Argh.
;;
;; Instead of leading \\b we need to use (?<![*\\w])
;; Instead of trailing \\b we need to use (?![*\\w])
(define word-boundary-open "(?<![*\\w])")
(define word-boundary-close "(?![*\\w])")

(define (bold xs)
  (replace xs (pregexp (str word-boundary-open    ;not \\b
                            "[_*]{2}(.+?)[_*]{2}"
                            word-boundary-close)) ;not \\b
           (lambda (_ x) `(strong ,x))))

(module+ test
  (check-equal? (bold '("no __YES__ no __YES__"))
                '("no " (strong "YES") " no " (strong "YES")))
  (check-equal? (bold '("no **YES** no **YES**"))
                '("no " (strong "YES") " no " (strong "YES")))
  (check-equal? (bold '("2*3*4"))
                '("2*3*4")))

(define (italic xs)
  ;; Complicated by need to handle \_literal underlines\_ and asterisks.
  (define (dethunk xs)
    (for/list ([x xs]) (if (procedure? x) (x) x)))
  (~> xs
      (replace #px"\\\\([_*])(.+?)\\\\([_*])"
               (lambda (_ open x close)
                 (thunk (str open x close)))) ;so no match next
      (replace (pregexp (str word-boundary-open    ;not \\b
                             "(?<!\\\\)[_*]{1}(.+?)[_*]{1}"
                             word-boundary-close)) ;not \\b
               (lambda (_ x) `(em ,x)))
      dethunk))

(module+ test
  (check-equal? (italic '("no _YES_ no _YES_"))
                '("no " (em "YES") " no " (em "YES")))
  (check-equal? (italic '("no *YES* no *YES*"))
                '("no " (em "YES") " no " (em "YES")))
  (check-equal? (italic '("no_no_no"))
                '("no_no_no"))
  (check-equal? (italic '("_YES_ no no_no _YES_YES_ _YES YES_"))
                '((em "YES") " no no_no " (em "YES_YES") " " (em "YES YES")))
  (check-equal? (italic '("\\_text surrounded by literal underlines\\_"))
                '("_text surrounded by literal underlines_"))
  (check-equal? (italic '("\\*text surrounded by literal asterisks\\*"))
                '("*text surrounded by literal asterisks*")))

(define (try re)
  (define xs (regexp-try-match re (current-input-port)))
  (and xs (map (lambda (x)
                 (and x (bytes->string/utf-8 x)))
               xs)))

(define (nuke-all s re [new ""])
  (regexp-replace* re s new))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Test

(module+ test
  (require racket/runtime-path)

  (define-runtime-path test.md "test/test.md")
  (define sample (parameterize ([current-allow-html? #t])
                   (with-input-from-file test.md read-markdown)))

  (define-runtime-path test.css "test/test.css")
  (define style `(link ([href ,(path->string test.css)]
                        [rel "stylesheet"]
                        [type "text/css"])))

  ;; Reference file. Check periodically.
  (define-runtime-path test.html "test/test.html")

  (define test.out.html (build-path (find-system-path 'temp-dir)
                                    "test.out.html"))

  (with-output-to-file test.out.html #:exists 'replace
                       (lambda ()
                         (~> `(html (head () ,style) (body () ,@sample))
                             xexpr->string
                             display)))

  (check-equal? (system/exit-code (str #:sep " "
                                       "diff" test.out.html test.html))
                0)
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Sample

(require racket/runtime-path)

(define-runtime-path test.md "test/test.md")
(define sample (parameterize ([current-allow-html? #t])
                 (with-input-from-file test.md read-markdown)))

;; (pretty-print sample)

(define-runtime-path test.css "test/test.css")
(define style `(link ([href ,(path->string test.css)]
                      [rel "stylesheet"]
                      [type "text/css"])))

(with-output-to-file "/tmp/markdown.html" #:exists 'replace
  (lambda ()
    (~> `(html (head () ,style) (body () ,@sample))
        xexpr->string
        display)))