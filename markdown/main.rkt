#lang rackjure

(require xml
         (prefix-in h: html)
         (only-in srfi/1 span))

(provide
 (contract-out [read-markdown (() (symbol?). ->* . (listof xexpr?))]
               [toc ((listof xexpr?) . -> . xexpr?)]
               [current-allow-html? (parameter/c boolean?)]
               [current-show-linkrefs-as-footnotes? (parameter/c boolean?)]
               [current-add-toc? (parameter/c boolean?)]
               [display-xexpr ((xexpr?) (0) . ->* . any)]))

(module+ test
  (require rackunit (submod "..")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Allow literal HTML in the markdown file to be passed through to the
;; output? If #f then the HTML is escaped.
(define current-allow-html? (make-parameter #t))

;; Show linkrefs as footnotes?
(define current-show-linkrefs-as-footnotes? (make-parameter #f))

;; Add table of contents?
(define current-add-toc? (make-parameter #f))

;; Current footnote number
(define footnote-number (make-parameter 0))
(define footnote-prefix (make-parameter (gensym)))

;; Returns (listof xexpr?) that may be spliced into a 'body element --
;; i.e. `(html () (head () (body () ,@(read-markdown))))
;;
;; The optional `footnote-prefix-symbol` argument should normally only
;; be supplied for purposes such as unit testing. Otherwise, this
;; defaults to (gensym). The purpose of this is to give a unique
;; prefix to footnote URIs for each run of `read-markdown`; it's a
;; sort of "namespace".  As a result, HTML from multiple runs of
;; `read-markdown` may be mixed on the same page without conflicting
;; links. Motivating use case: The Frog static blog generator can
;; create a page of posts sharing the same tag, and the posts may each
;; have footnotes and they can peacefully co-exist.
(define (read-markdown [footnote-prefix-symbol (gensym)])
  (parameterize ([current-refs (make-hash)]
                 [footnote-number 0]
                 [footnote-prefix footnote-prefix-symbol])
    (~> (read-blocks)
        maybe-add-toc
        resolve-refs
        remove-br-before-blocks)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; references (both reference links and footnotes)

(struct ref (id) #:transparent)         ;#:transparent so equal? works
(struct ref:link ref () #:transparent)  ;"  id is string?
(struct ref:note ref () #:transparent)  ;"  id is string?
(struct ref:back ref () #:transparent)  ;"  id is integer?

(define current-refs (make-parameter (make-hash))) ;ref? => ?

(define (resolve-refs xs) ;(listof ~xexpr?) -> (listof xexpr?)
  ;; Walk the ~xexprs looking for 'a elements whose 'href attribute is
  ;; ref?, and replace with hash value. Same for 'img elements 'src
  ;; attributes that are ref:link?
  (define (uri u)
    (cond [(ref? u) (get-ref u)]
          [else u]))
  (define (do-xpr x)
    (match x
      [`(a ,(list-no-order `[href ,href] more ...) ,body ...)
       `(a ([href ,(uri href)] ,@more) ,@(map do-xpr body))]
      [`(img ,(list-no-order `[src ,src] more ...) ,body ...)
       `(img ([src ,(uri src)] ,@more) ,@(map do-xpr body))]
      [`(,tag ([,k ,v] ...) ,body ...)
       `(,tag ,(map list k v) ,@(map do-xpr body))]
      [`(,tag ,body ...)
       `(,tag ,@(map do-xpr body))]
      [_ x]))
  (for/list ([x xs])
    (do-xpr x)))

(define (add-ref! ref uri) ;; ref? string? -> any
  (hash-set! (current-refs) ref uri))

(define (get-ref ref) ;; ref? -> string?
  (or (dict-ref (current-refs) ref #f)
      (begin (eprintf "Unresolved reference: '~a'\n" ref) "")))

(module+ test
  (check-equal? (parameterize ([current-refs (make-hash)])
                  (add-ref! (ref:link "foo") "bar")
                  (resolve-refs `((a ([href ,(ref:link "foo")]) "foo"))))
                '((a ((href "bar")) "foo"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; toc

(define (maybe-add-toc xs) ;; (listof xexpr?) -> (listof xexpr?)
  (cond [(current-add-toc?) (cons (toc xs) xs)]
        [else xs]))

(define (toc xs) ;; (listof xexpr?) -> xexpr?
  (define (do-list xs) ;; (listof head?) -> (listof xexpr?)
    (let loop ([xs xs])
      (match xs
        ['() '()]
        [(cons x more)
         ;; Get the span of `more` that's subitems, and the remainder
         (define (sub? a b) ;; is b's level > a -- e.g. h2 is sub of h1
           (< (head-level a) (head-level b)))
         (define-values (subs peers) (span (curry sub? x) more))
         ;; Make an xexpr (possibly empty) for the sublists (if any)
         (define (sub-xpr subs) (match subs
                                  ['() '()]
                                  [_ `((ul ,@(do-list subs)))]))
         ;; Make the `li` xexpr for this and any sublists
         (match-define (head level anchor body) x)
         (define li `(li (a ([href ,anchor]) ,@body)
                         ,@(sub-xpr subs)))
         (cons li (loop peers))])))

  (struct head (level anchor body))
  (define (match-head x) ;; xexpr -> (or/c head? #f)
    (match x
      [(list (and tag (or 'h1 'h2 'h3)) ;just first few levels
             (list 'a
                   (list-no-order (list 'name anchor)
                                  (list 'class _)))
             body ...)
       (define level (~> tag symbol->string (substring 1) string->number))
       (head level (str "#" anchor) body)]
      [_ #f]))

  `(div ([class "toc"])
        (ol ,@(do-list (filter-map match-head xs)))))

(module+ test
  (check-equal?
   (parameterize ([current-add-toc? #t])
     (with-input-from-string
         (str #:sep "\n\n" "# 1.0" "## 1.1" "# 2.0" "## 2.1" "")
       read-markdown))
   '((div ((class "toc"))
          (ol
           (li (a ((href "#1.0")) "1.0")
               (ul (li (a ((href "#1.1")) "1.1"))))
           (li (a ((href "#2.0")) "2.0")
               (ul (li (a ((href "#2.1")) "2.1"))))))
     (h1 (a ((name "1.0") (class "anchor"))) "1.0")
     (h2 (a ((name "1.1") (class "anchor"))) "1.1")
     (h1 (a ((name "2.0") (class "anchor"))) "2.0")
     (h2 (a ((name "2.1") (class "anchor"))) "2.1"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; block level

(define (read-blocks)
  (let loop ([xs '()])
    (define x (block-level))
    (cond [x (loop (append xs x))]
          [else xs])))

(define (remove-br-before-blocks xs)
  (match xs
    [(list) (list)]
    [(list (list 'br) (and next (list (or 'blockquote 'pre) _ ...)) more ...)
     (cons next (remove-br-before-blocks more))]
    [(list x more ...)
     (cons x (remove-br-before-blocks more))]))

(module+ test
  (check-equal?
   (remove-br-before-blocks
    '((br) (pre) (br) (p) (br) (blockquote) (br)))
   '((pre) (br) (p) (blockquote) (br))))

(define (block-level) ;; -> (or/c #f list?)
  (or (heading-block)
      (code-block-indent)
      (code-block-backtick)
      (blockquote)
      (hr-block) ;; must go BEFORE list block
      (list-block)
      (footnote-block)
      (linkref-block)
      (other-block)))

(define (hr-block) ;; no, not _that_ HR Block
  (match (try #px"^(?:[*-] ?){3,}\n+")
    [(list _) `((hr))]
    [_ #f]))

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
                           "[ ]{0,3}" marker ".+?" "\n{1,}"
                           "(?:$|(?=\\S))"
                           "(?![ \t]*" marker "[ \t]+)" ;; not another one
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
      [_ 'ol]))
  `(,tag
    ,@(for/list ([x xs])
        (match x
          ;; List item with a sublist?
          [(pregexp (str "^(.+?)\\s*" "(?<=\n)" "(\\s+ " marker ".+)$")
                    (list _ text sublist))
           `(li ,@(intra-block text) ,(do-list (outdent sublist)))]
          [_
           (match x
             ;; If the item ends in 2+ \n, nest the text in a
             ;; 'p element to get a space between it and the
             ;; next item. (We stripped \n\n from the very last
             ;; item, above.)
             [(pregexp "^(.*?)\n{2}$" (list _ text))
              `(li (p ,@(intra-block text)))]
             ;; Otherwise just goes directly in the 'li element.
             [(pregexp "^(.*?)\n*$" (list _ text))
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
                      "Bullet 2"
                      (ul (li "Bullet 2a")
                          (li "Bullet 2b"
                              (ul (li "Bullet 2bi")))))
                     (li "Bullet 3"
                         (ul (li "Bullet 3a")))
                     (li "Bullet 4 continued")
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
                  (li "One" (ol (li "One / One")
                                (li "One / Two")))
                  (li "Two" (ol (li "Two / One")
                                (li "Two / Two"))))))

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

(define (heading-block)
  (or (hash-heading-block)
      (equal-heading-block)
      (hyphen-heading-block)))

(define (hash-heading-block) ;; -> (or/c #f list?)
  (match (try #px"^\\s*(#+) ([^\n]+)\n\n")
    [(list _ pounds text)
     (define tag (~> (str "h" (string-length pounds))
                     string->symbol))
     `((,tag ,(anchor text) ,text))]
    [_ #f]))
              
(define (equal-heading-block) ;; -> (or/c #f list?)
  (match (try #px"^([^\n]+)\n={3,}\n{1,}")
    [(list _ text) `((h1 ,(anchor text) ,text))]
    [_ #f]))

(define (hyphen-heading-block) ;; -> (or/c #f list?)
  (match (try #px"^([^\n]+)\n-{3,}\n{1,}")
    [(list _ text) `((h2 ,(anchor text) ,text))]
    [_ #f]))

(define (anchor text)
  (define name (~> text (nuke-all #rx" " "-") string-downcase))
  `(a ([name ,name]
       [class "anchor"])))

(module+ test
  (check-false (with-input-from-string "Some normal text.\n" heading-block))
  (check-equal?
   (with-input-from-string "# Hi there\n\nNot part of header" heading-block)
   '((h1 (a ((name "hi-there") (class "anchor")))
         "Hi there")))
  (check-equal?
   (with-input-from-string "## Hi there\n\nNot part of header" heading-block)
   '((h2 (a ((name "hi-there") (class "anchor")))
         "Hi there")))
  (check-equal?
   (with-input-from-string "Hi there\n===\n\nNot part of header" heading-block)
   '((h1 (a ((name "hi-there") (class "anchor")))
         "Hi there")))
  (check-equal?
   (with-input-from-string "Hi there\n---\n\nNot part of header" heading-block)
   '((h2 (a ((name "hi-there") (class "anchor")))
         "Hi there")))
  (check-equal?
   (with-input-from-string "Requirements\n============\n" heading-block)
   '((h1 (a ((name "requirements") (class "anchor")))
         "Requirements"))))

(define (code-block-indent) ;; -> (or/c #f list?)
  (match (try #px"^([ ]{4,}.*?\n)+(?:$|(?:[ ]{0,3}\n))")
    [(list code _)
     `((pre ,(~> code
                 (nuke-all #px"^    ")
                 (nuke-all #px"\n    " "\n")
                 (nuke-all #px"\n+$"))))]
    [_ #f]))

(define (code-block-backtick) ;; -> (or/c #f list?)
  (match (try #px"^```(.*?)\n(.*?\n)```\n")
    [(list _ lang code)
     `((pre ,@(match lang
                ["" '()]
                [_ `(([class ,(str "brush: " lang)]))])
            ,(~> code (nuke-all #px"\n+$"))))]
    [_ #f]))

(define (blockquote) ;; -> (or/c #f list?)
  (match (try #px"^> (.+?\n\n)+?")
    [(list _ text)
     ;; Remove the `>`s, then run it through `other-block` to get its
     ;; paragraph detection.
     (define xs
       (parameterize ([current-input-port (~> text
                                              (nuke-all #px"\n>[ ]*" "\n")
                                              open-input-string)])
         (append*
          (let loop ()
            (match (other-block)
              [#f '()]
              [(var x) (cons x (loop))])))))
     `((blockquote ,@xs))]
    [_ #f]))

(module+ test
  (check-equal?
   (with-input-from-string (str #:sep "\n"
                                "> Foo"
                                "> Foo"
                                ">"
                                "> Foo"
                                "> Foo"
                                ""
                                "")
     blockquote)
   '((blockquote (p "Foo Foo") (p "Foo Foo")))))

(define (footnote-block)
  (match (try (pregexp (str "^"
                            "\\[\\^(.+?)\\]:\\s*"
                            "(.+?)"
                            "(?:$|(?:\n[ ]{0,3}\n))"
                            )))
    [(list _ label text)
     (define num (get-ref (ref:back label)))
     (define back-href (str "#" (footnote-prefix) "-footnote-" num "-return"))
     (define anchor (str (footnote-prefix) "-footnote-" num "-definition"))
     (add-ref! (ref:note label) (str "#" anchor))
     `((a ([name ,anchor]))
       ,@(parameterize ([current-input-port
                         (~> (str (~a num) ": " text
                                  " [↩](" back-href ")")
                             (nuke-all #px"^    ")
                             (nuke-all #px"\n    " "\n")
                             (nuke-all #px"\n+$")
                             open-input-string)])
           (read-blocks)))]
    [_ #f]))

(module+ test
  (parameterize ([current-refs (make-hash)]
                 [footnote-prefix (gensym)])
    (add-ref! (ref:back "1") 1)
    (check-equal?
     (with-input-from-string "[^1]: Some stuff\n\nIgnore me." footnote-block)
     `((a ([name ,(str (footnote-prefix) "-footnote-1-definition")]))
       (p "1: Some stuff "
          (a ([href ,(str "#" (footnote-prefix) "-footnote-1-return")]) "↩"))))
    (check-equal?
     (with-input-from-string
         (str #:sep "\n"
              "[^1]: The first paragraph of the definition."
              "    "
              "    Paragraph two of the definition."
              "    "
              "    > A blockquote with"
              "    > multiple lines."
              "    "
              "        a code block"
              "        here"
              "    "
              "    A final paragraph."
              "")
       footnote-block)
     `((a ([name ,(str (footnote-prefix) "-footnote-1-definition")]))
       (p "1: The first paragraph of the definition.")
       (p "Paragraph two of the definition.")
       (blockquote (p "A blockquote with multiple lines."))
       (pre "a code block\nhere")
       (p "A final paragraph. "
          (a ((href ,(str "#" (footnote-prefix) "-footnote-1-return"))) "↩"))))))

(define (linkref-block)
  ;; - Square brackets containing the link identifier (optionally
  ;;   indented from the left margin using up to three spaces);
  ;;
  ;; - followed by a colon;
  ;;
  ;; - followed by one or more spaces (or tabs);
  ;;
  ;; - followed by the URL for the link;
  ;;
  ;; - optionally followed by a title attribute for the link, enclosed
  ;;   in double or single quotes, or enclosed in parentheses.
  (match (try (pregexp (str "^"
                            "[ \t]{0,3}\\[(.+?)\\]:"
                            "[ \t]{1,}(\\S+)"
                            "(?:\\s+[\"'(](.+?)[\"')])?"
                            "\\s*\n+")))
    [(list _ refname uri title)
     (add-ref! (ref:link refname) uri)
     (cond [(current-show-linkrefs-as-footnotes?)
            `((p ,(str "[" refname "]")
                 ,@(cond [title `((em ,title))]
                         [else `()])
                 ": " (a ([href ,uri]) ,uri)))]
           [else `("")])]
    [_ #f]))

(module+ test
  (define-syntax-rule (chk s)
    (check-equal?
     (parameterize ([current-show-linkrefs-as-footnotes? #t])
       (with-input-from-string (str s "\n") linkref-block))
     '((p "[foo]" (em "Optional Title Here") ": "
          (a ((href "http://example.com/")) "http://example.com/")))))
  (chk "[foo]: http://example.com/  \"Optional Title Here\"")
  (chk "   [foo]:   http://example.com/     \"Optional Title Here\"")
  (chk "[foo]: http://example.com/  'Optional Title Here'")
  (chk "[foo]: http://example.com/  (Optional Title Here)")
  ;; No title
  (check-equal?
   (parameterize ([current-show-linkrefs-as-footnotes? #t])
     (with-input-from-string "[0]: path/to/thing\n" linkref-block))
   '((p "[0]" ": " (a ((href "path/to/thing")) "path/to/thing")))))

;; Look for a specific bug in resolve-refs that I encountered with a
;; reflink in blockquote:
(module+ test
  (let ([s (str #:sep "\n"
                 "> I am [reflink][] here."
                 ""
                 "Blah blah blah"
                 ""
                 "[reflink]: http://www.example.com"
                 "")])
    (check-equal?
     (with-input-from-string s read-markdown)
     '((blockquote (p "I am "
                      (a ([href "http://www.example.com"]) "reflink")
                      " here."))
       (p "Blah blah blah") ""))))

(define (other-block) ;; -> (or/c #f list?)
  (match (try #px"^(.+?)(?:$|\n$|\n{2,})")
    [(list _ text)
     `((p ,@(intra-block text)))]
    [_
     (let ([s (read-line (current-input-port) 'any)])
       (and (not (eof-object? s))
            `(,@(intra-block (str s "\n")))))]))

(define (try re)
  (define xs (regexp-try-match re (current-input-port)))
  (and xs (map (lambda (x)
                 (and x (bytes->string/utf-8 x)))
               xs)))

(define (nuke-all s re [new ""])
  (regexp-replace* re s new))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; intra-block

(define (intra-block s) ;; s -> (listof xexpr?)
  ;; Look for formatting within a block
  (~> s
      list
      escape ;; before everything
      code ;; before everything else
      space&space&newline->br
      newline&spaces->space
      html
      entity-tag
      image
      footnote ;; before `link`
      link
      auto-link
      bold
      italic
      dashes
      remove-br-before-blocks
      unescape
      ))

(module+ test
  (check-equal? (intra-block "The expression `2 * foo_bar`")
                '("The expression " (code "2 * foo_bar"))))

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
                      [_ x])))]
                [else (list x)]))
        xs)))

(define (escape xs)
  (replace xs "\\\\(.)" (lambda (_ x) (list 'ESCAPE x))))

(define (unescape xs)
  (for/list ([x xs])
    (match x
      [(list 'ESCAPE text) text]
      [_ x])))

(module+ test
  (check-equal? (~> '("\\`not code`") escape)
                '((ESCAPE "`") "not code`"))
  (check-equal? (~> '("\\`not code`") escape unescape)
                '("`" "not code`")))


(define (code xs)
  (define (code-xexpr _ x) `(code ,x))
  (~> xs
      (replace #px"`` ?(.+?) ?``" code-xexpr)
      (replace #px"`(.+?)`" code-xexpr)))

(module+ test
  ;; See http://daringfireball.net/projects/markdown/syntax#code
  (check-equal? (code '("This is some `inline code` here"))
                '("This is some "
                  (code "inline code")
                  " here"))
  (check-equal? (code '(" `` ` `` "))
                '(" " (code "`") " "))
  (check-equal? (code '(" `` `foo` ``"))
                '(" " (code "`foo`")))
  (check-equal? (code '("``There is a literal backtick (`) here.``"))
                '((code "There is a literal backtick (`) here."))))

(define (entity-tag xs)
  (~> xs
      (replace #px"&(\\w+);" (lambda (_ x) (string->symbol x)))))

(module+ test
  (check-equal?
   (entity-tag '("Copyright &copy; 2013 by The Dude & another guy; truly"))
   '("Copyright " copy " 2013 by The Dude & another guy; truly")))

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

(define (newline&spaces->space xs)
  (for/list ([x (in-list xs)])
    (cond [(string? x) (regexp-replace* #px"\n\\s*" x " ")]
          [else x])))

(define (image xs)
  (~> xs
      (replace #px"!\\[(.*?)\\]\\(([^ ]+)(\\s+\"(.+?)\"\\s*)?\\)" ;normal
           (lambda (_ alt src __ title)
             `(img ([alt ,alt] [src ,src] [title ,(or title "")]))))
      (replace #px"!\\[(.*?)\\]\\[([^ ]+)\\]" ;reflink
           (lambda (_ alt src)
             `(img ([alt ,alt] [src ,(string->symbol src)]))))))

(module+ test
  (check-equal? (image '("![Alt text](/path/to/img.png)"))
                '((img ((alt "Alt text")
                        (src "/path/to/img.png")
                        (title "")))))
  (check-equal? (image '("![Alt text](/path/to/img.png \"Title\")"))
                '((img ((alt "Alt text")
                        (src "/path/to/img.png")
                        (title "Title")))))
  (check-equal? (image '("![Alt text][1]"))
                '((img ((alt "Alt text")
                        (src |1|))))))

(define (footnote xs)
  (~> xs
      (replace #px"\\[\\^(.*?)\\]" ;normal
               (lambda (_ label)
                 (footnote-number (add1 (footnote-number)))
                 (define anchor (str (footnote-prefix)
                                     "-footnote-"
                                     (footnote-number)
                                     "-return"))
                 (add-ref! (ref:back label) (footnote-number))
                 `(sup (a ([href ,(ref:note label)]
                           [name ,anchor])
                          ,(number->string (footnote-number))))))))

(module+ test
  (parameterize ([footnote-number 0]
                 [footnote-prefix (gensym)])
    (check-equal? (footnote '("Footnote[^1]"))
                  `("Footnote" (sup (a ([href ,(ref:note "1")]
                                        [name ,(str (footnote-prefix)
                                                    "-footnote-1-return")])
                                       "1")))))
  (parameterize ([footnote-number 0]
                 [footnote-prefix (gensym)])
    (check-equal? (footnote '("Footnote [^1]."))
                  `("Footnote " (sup (a ([href ,(ref:note "1")]
                                         [name ,(str (footnote-prefix)
                                                     "-footnote-1-return")])
                                        "1")) "."))))

(define (link xs)
  (~> xs
      (replace #px"\\[(.*?)\\][ ]{0,1}\\((.+?)\\)" ;normal
               (lambda (_ text href)
                 `(a ([href ,href]) ,text)))
      (replace #px"\\[(.+?)\\][ ]{0,1}\\[(.*?)\\]" ;reflink (resolve later)
               (lambda (_ text href)
                 (let ([href (match href ["" text][_ href])])
                   `(a ([href ,(ref:link href)]) ,text))))))

(module+ test
  (check-equal? (link '("[Google](http://www.google.com/)"))
                '((a ((href "http://www.google.com/")) "Google")))
  (check-equal? (link '("[Google] (http://www.google.com/)"))
                '((a ((href "http://www.google.com/")) "Google")))
  (check-equal? (link '("[Google][1]"))
                `((a ((href ,(ref:link "1"))) "Google")))
  (check-equal? (link '("[Google][]"))
                `((a ((href ,(ref:link "Google"))) "Google")))
  (check-equal? (link '("[Google] [1]"))
                `((a ((href ,(ref:link "1"))) "Google"))))

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
  (replace xs (pregexp (str word-boundary-open    ;not \\b
                            "(?<!\\\\)[_*]{1}(.+?)[_*]{1}"
                            word-boundary-close)) ;not \\b
           (lambda (_ x) `(em ,x))))

(module+ test
  (check-equal? (italic '("no _YES_ no _YES_"))
                '("no " (em "YES") " no " (em "YES")))
  (check-equal? (italic '("no *YES* no *YES*"))
                '("no " (em "YES") " no " (em "YES")))
  (check-equal? (italic '("no_no_no"))
                '("no_no_no"))
  (check-equal? (italic '("_YES_ no no_no _YES_YES_ _YES YES_"))
                '((em "YES") " no no_no " (em "YES_YES") " " (em "YES YES")))
  (check-equal? (intra-block "\\_text surrounded by literal underlines\\_")
                '("_" "text surrounded by literal underlines" "_"))
  (check-equal? (intra-block "\\*text surrounded by literal asterisks\\*")
                '("*" "text surrounded by literal asterisks" "*")))

(define (dashes xs)
  (~> xs
      (replace #px" -- "
               (lambda (_) '(span " " ndash " ")))
      (replace #px"\\b--\\b"
               (lambda (_) '(span mdash)))))

(module+ test
  (check-equal? (dashes '("This -- section -- is here and this--is--here."))
                '("This" (span " " ndash " ") "section" (span " " ndash " ")
                  "is here and this" (span mdash) "is" (span mdash) "here.")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; display-xexpr

;; xexpr->string does too little formatting, and display-xml does too
;; much.  This is the warm bowl of porridge.

(define current-pre (make-parameter 0))

(define (display-xexpr x [indent 0])
  (define escape-table #rx"[<>&]")
  (define escape-attribute-table #rx"[<>&\"]")

  (define (replace-escaped s)
    (case (string-ref s 0)
      [(#\<) "&lt;"]
      [(#\>) "&gt;"]
      [(#\&) "&amp;"]
      [(#\") "&quot;"]))

  (define (escape x table)
    (regexp-replace* table x replace-escaped))

  (define (do tag ks vs body)
    (when (eq? tag 'pre)
      (current-pre (add1 (current-pre))))
    (define-values (newline-str indent-str)
      (cond [(> (current-pre) 1) (values "" "")]
            [(memq tag '(a code em img span strong sup)) (values "" "")]
            [else (values "\n" (make-string indent #\space))]))
    (cond [(and (empty? ks) (empty? body))
           (printf "~a~a<~a />" newline-str indent-str tag)]
          [else
           (printf "~a~a<~a" newline-str indent-str tag)
           (for ([k ks]
                 [v vs])
             (printf " ~a=\"~a\"" k (escape v escape-attribute-table)))
           (printf ">")
           (for ([b body])
             (display-xexpr b (+ 1 indent)))
           (printf "</~a>" tag)])
    (when (eq? tag 'pre)
      (current-pre (sub1 (current-pre)))))

  (match x
    [(list (? symbol? tag) (list (list ks vs) ...) els ...) (do tag ks vs els)]
    [(list tag els ...) (do tag '() '() els)]
    [(? symbol? x) (~> (format "&~a;" x) display)]
    [(? integer? x) (~> (format "&#~a;" x) display)]
    [_ (~> x ~a (escape escape-table) display)]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Unit test: Compare to static file.

(define test-footnote-prefix 'unit-test) ;fixed, not from (gensym)

(module+ test
  (require racket/runtime-path)

  (define-runtime-path test.md "test/test.md")
  (define xs (parameterize ([current-allow-html? #t]
                            [current-add-toc? #f]
                            [current-show-linkrefs-as-footnotes? #f])
               (with-input-from-file test.md
                 (thunk (read-markdown test-footnote-prefix)))))

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
                         (~> `(html (head ()
                                          ,style
                                          (meta ([charset "utf-8"])))
                                    (body () ,@xs))
                             display-xexpr)))

  (check-equal? (system/exit-code (str #:sep " "
                                       "diff" test.html test.out.html))
                0))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Unit tests: EOF
;;
;; Boundary case for bugs is things appearing at the very EOF.

(module+ test
  (define-syntax-rule (check-eof str xpr)
    (check-equal? (parameterize ([current-add-toc? #f]
                                 [footnote-number 0])
                    (with-input-from-string str read-markdown))
                  xpr))
  ;; List
  (check-eof "- Bullet 1\n- Bullet 2\n"
             '((ul (li "Bullet 1") (li "Bullet 2"))))
  ;; List
  (check-eof "- Bullet 1\n  - Bullet 1a\n- Bullet 2\n  - Bullet 2a\n"
             '((ul (li "Bullet 1" (ul (li "Bullet 1a")))
                   (li "Bullet 2" (ul (li "Bullet 2a"))))))
  ;; Header
  (check-eof "# Header 1\n\n"
             '((h1 (a ((name "header-1") (class "anchor")))
                   "Header 1")))
  ;; Code block: ticks
  (check-eof "```\nCode block\n```\n"
             '((pre "Code block")))
  ;; Code block: indent
  (check-eof "    Code block\n"
             '((pre "Code block")))
  ;; Blockquote
  (check-eof "> Block quote here\n\n"
             '((blockquote (p "Block quote here"))))
  ;; hr
  (check-eof "---\n"
             '((hr)))
  ;; Linkref
  (parameterize ([current-show-linkrefs-as-footnotes? #t])
    (check-eof "An [example link][0]\n\n[0]: http://www.example.com/ \"Improbable Research\"\n"
               '((p "An " (a ((href "http://www.example.com/"))
                             "example link"))
                 (p "[0]" (em "Improbable Research") ": "
                    (a ((href "http://www.example.com/"))
                       "http://www.example.com/")))))
  (parameterize ([current-show-linkrefs-as-footnotes? #f])
    (check-eof "An [example link][0]\n\n[0]: http://www.example.com/ \"Improbable Research\"\n"
               '((p "An " (a ((href "http://www.example.com/"))
                             "example link"))
                 "")))
  ;; p
  (check-eof "Foo"     '((p "Foo")))
  (check-eof "Foo\n"   '((p "Foo")))
  (check-eof "Foo\n\n" '((p "Foo")))
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Main

(module+ main
  (~> `(html (head () (meta ([charset "utf-8"])))
             (body () ,@(read-markdown)))
      display-xexpr))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; The following is just for interactive development. Also for creating an
;; updated test/test.html for unit test.

;; (require racket/runtime-path)

;; (define-runtime-path test.md "test/test.md")
;; (define xs (parameterize ([current-allow-html? #t]
;;                           [footnote-number 0])
;;              (with-input-from-file test.md
;;                (thunk (read-markdown test-footnote-prefix)))))

;; (define-runtime-path test.css "test/test.css")
;; (define style `(link ([href ,(path->string test.css)]
;;                       [rel "stylesheet"]
;;                       [type "text/css"])))

;; (with-output-to-file "/tmp/markdown.html"
;;   #:exists 'replace
;;   (lambda ()
;;     (~> `(html (head ()
;;                      ,style
;;                      (meta ([charset "utf-8"])))
;;                (body ()
;;                      ,@xs))
;;         display-xexpr)))