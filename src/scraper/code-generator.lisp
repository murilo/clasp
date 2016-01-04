(in-package :cscrape)

(defparameter +root-dummy-class+ "::_RootDummyClass")
(define-condition bad-c++-name (error)
  ((name :initarg :name :accessor name))
  (:report (lambda (condition stream)
             (format stream "Bad C++ function name: ~a" (name condition)))))

(defun group-expose-functions-by-namespace (functions)
  (declare (optimize (debug 3)))
  (let ((ns-hashes (make-hash-table :test #'equal)))
    (dolist (func functions)
      (let* ((namespace (namespace% func))
             (ns-ht (gethash namespace ns-hashes (make-hash-table :test #'equal))))
        (setf (gethash (lisp-name% func) ns-ht) func)
        (setf (gethash namespace ns-hashes) ns-ht)))
    ns-hashes))

(defun generate-expose-function-signatures (sout ns-grouped-expose-functions)
  (format sout "#ifdef EXPOSE_FUNCTION_SIGNATURES~%")
  (maphash (lambda (ns func-ht)
             (format sout "namespace ~a {~%" ns)
             (maphash (lambda (name f)
                        (declare (ignore name))
                        (when (and (typep f 'expose-internal-function)
                                   (provide-declaration% f))
                          (format sout "    ~a;~%" (signature% f))))
                      func-ht)
             (format sout "};~%"))
           ns-grouped-expose-functions)
  (format sout "#endif // EXPOSE_FUNCTION_SIGNATURES~%"))

#+(or)(defun split-c++-name (name)
        (declare (optimize (debug 3)))
        (let ((under (search "__" name :test #'string=)))
          (unless under
            (error 'bad-c++-name :name name))
          (let* ((name-pos (+ 2 under)))
            (values (subseq name 0 under)
                    (subseq name name-pos)))))

(defun maybe-wrap-lambda-list (ll)
  (if (> (length ll) 0)
      (format nil "(~a)" ll)
      ll))
(defun generate-expose-function-bindings (sout ns-grouped-expose-functions)
  (declare (optimize (debug 3)))
  (flet ((expose-one (f ns)
           (etypecase f
             (expose-internal-function
              (format sout "  expose_function(~a,~a,&~a::~a,~s);~%"
                      (lisp-name% f)
                      "true"
                      ns
                      (function-name% f)
                      (maybe-wrap-lambda-list (lambda-list% f))))
             (expose-external-function
              (format sout "  expose_function(~a,~a,~a,~s);~%"
                      (lisp-name% f)
                      "true"
                      (pointer% f)
                      (maybe-wrap-lambda-list (lambda-list% f)))))))
    (format sout "#ifdef EXPOSE_FUNCTION_BINDINGS~%")
    (maphash (lambda (ns funcs-ht)
               (maphash (lambda (name f)
                          (declare (ignore name))
                          (handler-case
                              (expose-one f ns)
                            (serious-condition (condition)
                              (error "There was an error while exposing a function in ~a at line ~d~%~a~%" (file% f) (line% f) condition))))
                        funcs-ht))
             ns-grouped-expose-functions)
    (format sout "#endif // EXPOSE_FUNCTION_BINDINGS~%")))



(defun generate-expose-one-source-info (sout func)
  (let* ((lisp-name (lisp-name% func))
         (file (file% func))
         (line (line% func))
         (char-offset (character-offset% func))
         (docstring (docstring% func)))
    (format sout " define_source_info( ~a, ~s, ~d, ~d, ~a );~%"
            lisp-name file char-offset line docstring )))

(defun generate-expose-source-info (sout functions classes cppdefine)
  (format sout "#ifdef ~a~%" cppdefine)
  (dolist (f functions)
    (generate-expose-one-source-info sout f))
  #+(or)(maphash (lambda (k class)
             (generate-expose-one-source-info sout class)
             (dolist (method (methods% class))
               (generate-expose-one-source-info sout method)))
           classes)
  (format sout "#endif // ~a~%" cppdefine))

(defun generate-code-for-source-info (functions classes)
  (with-output-to-string (sout)
    (generate-expose-source-info sout functions classes "SOURCE_INFO")))


#+(or)(defun generate-tags-file (tags-file-name tags)
        (declare (optimize (debug 3)))
        (let* ((source-info-tags (extract-unique-source-info-tags tags))
               (file-ht (make-hash-table :test #'equal)))
          (dolist (tag source-info-tags)
            (push tag (gethash (tags:file tag) file-ht)))
          (let ((tags-data-ht (make-hash-table :test #'equal)))
            (maphash (lambda (file-name file-tags-list)
                       (let ((buffer (make-string-output-stream #+(or):element-type #+(or)'(unsigned-byte 8))))
                         (dolist (tag file-tags-list)
                           (format buffer "~a~a~a,~a~%"
                                   (tags:function-name tag)
                                   (code-char #x7f)
                                   (tags:line tag)
                                   (tags:character-offset tag)))
                         (setf (gethash file-name tags-data-ht) (get-output-stream-string buffer))))
                     file-ht)
            (with-open-file (sout tags-file-name :direction :output #+(or):element-type #+(or)'(unsigned-byte 8)
                                  :if-exists :supersede)
              (maphash (lambda (file buffer)
                         (format sout "~a,~a~%"
                                 file
                                 (length buffer))
                         (princ buffer sout))
                       tags-data-ht)))))

(defun generate-code-for-init-functions (functions)
  (declare (optimize (debug 3)))
  (with-output-to-string (sout)
    (let ((ns-grouped (group-expose-functions-by-namespace functions)))
      (generate-expose-function-signatures sout ns-grouped)
      (generate-expose-function-bindings sout ns-grouped))))

(defun inherits-from* (x-name y-name inheritance)
  (let ((depth 0)
        ancestor
        prev-ancestor)
    (loop
       (setf prev-ancestor ancestor
             ancestor (gethash x-name inheritance))
       (when (string= ancestor +root-dummy-class+)
         (return-from inherits-from* nil))
       (unless ancestor
         (error "Hit nil in inherits-from*  prev-ancestor = ~a" prev-ancestor))
       (if (string= ancestor y-name)
           (return-from inherits-from* t))
       (incf depth)
       (when (> depth 20)
         (error "inherits-from* depth ~a exceeds max" depth))
       (setf x-name ancestor))))

(defun inherits-from (x y inheritance)
  (declare (optimize debug))
  (let ((x-name (class-key% x))
        (y-name (class-key% y)))
    (inherits-from* x-name y-name inheritance)))

(defparameter *classes* nil)
(defparameter *inheritance* nil)
(defun sort-classes-by-inheritance (exposed-classes)
  (declare (optimize debug))
  (let ((inheritance (make-hash-table :test #'equal))
        (classes nil))
    (maphash (lambda (k v)
               (let ((base (base% v)))
                 (when base (setf (gethash k inheritance) base))
                 (push v classes)))
             exposed-classes)
    (setf *classes* classes)
    (setf *inheritance* inheritance)
    (format t "About to sort classes~%")
    (sort classes (lambda (x y)
                    (not (inherits-from x y inheritance))))))

(defun generate-code-for-init-classes-class-symbols (exposed-classes sout)
  (declare (optimize (debug 3)))
  (let ((sorted-classes (sort-classes-by-inheritance exposed-classes))
        cur-package)
    (format sout "#ifdef SET_CLASS_SYMBOLS~%")
    (dolist (exposed-class sorted-classes)
      (format sout "set_one_static_class_symbol<~a::~a>(bootStrapSymbolMap,~a);~%"
              (tags:namespace% (class-tag% exposed-class))
              (tags:name% (class-tag% exposed-class))
              (lisp-name% exposed-class)))
    (format sout "#endif // SET_CLASS_SYMBOLS~%")))

(defun as-var-name (ns name)
  (format nil "~a_~a_var" ns name))

(defun generate-code-for-init-classes-and-methods (exposed-classes)
  (declare (optimize (debug 3)))
  (with-output-to-string (sout)
    (let ((sorted-classes (sort-classes-by-inheritance exposed-classes))
          cur-package)
      (generate-code-for-init-classes-class-symbols exposed-classes sout)
      (progn
        (format sout "#ifdef ALLOCATE_ALL_CLASSES~%")
        (dolist (exposed-class sorted-classes)
          (format sout "gctools::smart_ptr<~a> ~a = allocate_one_class<~a::~a,~a>();~%"
                  (meta-class% exposed-class)
                  (as-var-name (tags:namespace% (class-tag% exposed-class))
                               (tags:name% (class-tag% exposed-class)))
                  (tags:namespace% (class-tag% exposed-class))
                  (tags:name% (class-tag% exposed-class))
                  (meta-class% exposed-class)))
        (format sout "#endif // ALLOCATE_ALL_CLASSES~%"))
      (progn
        (format sout "#ifdef SET_BASES_ALL_CLASSES~%")
        (dolist (exposed-class sorted-classes)
          (unless (string= (base% exposed-class) +root-dummy-class+)
            (format sout "~a->addInstanceBaseClassDoNotCalculateClassPrecedenceList(~a::static_classSymbol());~%"
                    (as-var-name (tags:namespace% (class-tag% exposed-class))
                                 (tags:name% (class-tag% exposed-class)))
                    (base% exposed-class))))
        (format sout "#endif // SET_BASES_ALL_CLASSES~%"))
      (progn
        (format sout "#ifdef CALCULATE_CLASS_PRECEDENCE_ALL_CLASSES~%")
        (dolist (exposed-class sorted-classes)
          (unless (string= (base% exposed-class) +root-dummy-class+)
            (format sout "~a->__setupStage3NameAndCalculateClassPrecedenceList(~a::static_classSymbol());~%"
                    (as-var-name (tags:namespace% (class-tag% exposed-class))
                                 (tags:name% (class-tag% exposed-class)))
                    (base% exposed-class))))
        (format sout "#endif //#ifdef CALCULATE_CLASS_PRECEDENCE_ALL_CLASSES~%"))
      (progn
        (format sout "#ifdef EXPOSE_CLASSES_AND_METHODS~%")
        (dolist (exposed-class sorted-classes)
          (format sout "~a::~a::expose_to_clasp();~%"
                  (tags:namespace% (class-tag% exposed-class))
                  (tags:name% (class-tag% exposed-class))))
        (format sout "#endif //#ifdef EXPOSE_CLASSES_AND_METHODS~%"))
      (progn
        (format sout "#ifdef EXPOSE_CLASSES~%")
        (dolist (exposed-class sorted-classes)
          (when (string/= cur-package (package% exposed-class))
            (when cur-package (format sout "#endif~%"))
            (setf cur-package (package% exposed-class))
            (format sout "#ifdef Use_~a~%" cur-package))
          (format sout "DO_CLASS(~a,~a,~a,~a,~a,~a);~%"
                  (tags:namespace% (class-tag% exposed-class))
                  (subseq (class-key% exposed-class) (+ 2 (search "::" (class-key% exposed-class))))
                  (package% exposed-class)
                  (lisp-name% exposed-class)
                  (base% exposed-class)
                  (meta-class% exposed-class)))
        (format sout "#endif~%")
        (format sout "#endif // EXPOSE_CLASSES~%"))
      (progn
        (format sout "#ifdef EXPOSE_METHODS~%")
        (dolist (exposed-class sorted-classes)
          (let ((class-tag (class-tag% exposed-class)))
            (format sout "namespace ~a {~%" (tags:namespace% class-tag))
            (format sout "void ~a::expose_to_clasp() {~%" (tags:name% class-tag))
            (format sout "    ~a<~a>()~%"
                    (if (typep exposed-class 'exposed-external-class)
                        "core::externalClass_"
                        "core::class_")
                    (tags:name% class-tag))
            (dolist (method (methods% exposed-class))
              (if (typep method 'expose-internal-method)
                  (let* ((lisp-name (lisp-name% method))
                         (class-name (tags:name% class-tag))
                         (method-name (method-name% method))
                         (lambda-list (lambda-list% method))
                         (declare-form (declare% method)))
                    (format sout "        .def(~a,&~a::~a,R\"lambda(~a)lambda\",R\"decl(~a)decl\")~%"
                            lisp-name
                            class-name
                            method-name
                            (if (string/= lambda-list "")
                                (format nil "(~a)" lambda-list)
                                lambda-list)
                            declare-form))
                  (let* ((lisp-name (lisp-name% method))
                         (pointer (pointer% method))
                         (lambda-list (lambda-list% method))
                         (declare-form (declare% method)))
                    (format sout "        .def(~a,~a,R\"lambda(~a)lambda\",R\"decl(~a)decl\")~%"
                            lisp-name
                            pointer
                            (if (string/= lambda-list "")
                                (format nil "(~a)" lambda-list)
                                lambda-list)
                            declare-form))
                  ))
            (format sout "     ;~%")
            (format sout "}~%")
            (format sout "};~%")))
        (format sout "#endif // EXPOSE_METHODS~%")))))
          
(defparameter *unique-symbols* nil)
(defparameter *symbols-by-package* nil)
(defparameter *symbols-by-namespace* nil)
(defun generate-code-for-symbols (packages-to-create symbols)
  (declare (optimize (debug 3)))
  ;; Uniqify the symbols
  (with-output-to-string (sout)
    (let (unique-packages
          (symbols-by-package (make-hash-table :test #'equal))
          (symbols-by-namespace (make-hash-table :test #'equal))
          (index 0))
      (setq *symbols-by-package* symbols-by-package)
      (setq *symbols-by-namespace* symbols-by-namespace)
      ;; Organize symbols by package
      (dolist (symbol symbols)
        (pushnew symbol
                 (gethash (package% symbol) symbols-by-package)
                 :test #'string=
                 :key (lambda (x)
                        (c++-name% x)))
        (pushnew symbol
                 (gethash (namespace% symbol) symbols-by-namespace)
                 :test #'string=
                 :key (lambda (x)
                        (c++-name% x)))) 
     (progn
       (format sout "#if defined(BOOTSTRAP_PACKAGES)~%")
       (mapc (lambda (pkg)
               (format sout "{~%")
               (format sout "  std::list<std::string> use_packages = {~{ ~s~^, ~}};~%" (packages-to-use% pkg))
               (format sout "  bootStrapSymbolMap->add_package_info(~s,use_packages);~%" (name% pkg))
               (format sout "}~%"))
             packages-to-create)
       (format sout "#endif // #if defined(BOOTSTRAP_PACKAGES)~%"))
     (progn
        (format sout "#if defined(CREATE_ALL_PACKAGES)~%")
        (mapc (lambda (pkg)
                (format sout "{~%")
                (format sout "  std::list<std::string> nicknames = {~{ ~s~^, ~}};~%" (nicknames% pkg))
                (format sout "  std::list<std::string> use_packages = {};~%" ) ;; {~{ ~s~^, ~}};~%" (packages-to-use% pkg))
                (format sout "  if (!_lisp->recognizesPackage(~s)) {~%" (name% pkg) )
                (format sout "      _lisp->makePackage(~s,nicknames,use_packages);~%" (name% pkg))
                (format sout "  }~%")
                (format sout "}~%"))
              packages-to-create)
        (mapc (lambda (pkg)
                (when (packages-to-use% pkg)
                  (mapc (lambda (use)
                          (format sout "  gc::As<core::Package_sp>(_lisp->findPackage(~s))->usePackage(gc::As<core::Package_sp>(_lisp->findPackage(~s)));~%" (name% pkg) use))
                        (packages-to-use% pkg))))
              packages-to-create)
        (format sout "#endif~%"))
      (progn
        (format sout "#if defined(DECLARE_ALL_SYMBOLS)~%")
        (maphash (lambda (namespace namespace-symbols)
                   (format sout "namespace ~a {~%" namespace)
                   (dolist (symbol namespace-symbols)
                     (format sout "core::Symbol_sp _sym_~a;~%"
                             (c++-name% symbol)))
                   (format sout "} // namespace ~a~%" namespace))
                 symbols-by-namespace)
        (format sout "#endif~%"))
      (progn
        (format sout "#if defined(ALLOCATE_ALL_SYMBOLS)~%")
        (dolist (p packages-to-create)
          (maphash (lambda (namespace namespace-symbols)
                     (dolist (symbol namespace-symbols)
                       (when (string= (name% p) (package-str% symbol))
                         (format sout " ~a::_sym_~a = bootStrapSymbolMap->maybe_allocate_unique_symbol(\"~a\",core::lispify_symbol_name(~s), ~a);~%"
                                 namespace
                                 (c++-name% symbol)
                                 (package-str% symbol)
                                 (lisp-name% symbol)
                                 (if (typep symbol 'expose-internal-symbol)
                                     "false"
                                     "true")))))
                   symbols-by-namespace))
        (format sout "#endif~%"))
      (progn
        (format sout "#if defined(GARBAGE_COLLECT_ALL_SYMBOLS)~%")
        (maphash (lambda (namespace namespace-symbols)
                   (dolist (symbol namespace-symbols)
                     (format sout "SMART_PTR_FIX(~a::_sym_~a);~%"
                             namespace
                             (c++-name% symbol))))
                 symbols-by-namespace)
        (format sout "#endif~% // defined(GARBAGE_COLLECT_ALL_SYMBOLS~%"))
      (progn
        (maphash (lambda (package package-symbols)
                   (format sout "#if defined(~a_SYMBOLS)~%" package)
                   (dolist (symbol package-symbols)
                     (format sout "DO_SYMBOL(~a,_sym_~a,~d,~a,~s,~a);~%"
                             (namespace% symbol)
                             (c++-name% symbol)
                             index
                             (package% symbol)
                             (lisp-name% symbol)
                             (if (typep symbol 'expose-internal-symbol)
                                 "false"
                                 "true"))
                     (incf index))
                   (format sout "#endif // ~a_SYMBOLS~%" package))
                 symbols-by-package)))))

(defun generate-code-for-enums (enums)
  (declare (optimize (debug 3)))
  ;; Uniqify the symbols
  (with-output-to-string (sout)
    (format sout "#ifdef ALL_ENUMS~%")
    (dolist (e enums)
      (format sout "core::enum_<~a>(~a,~s)~%"
              (type% (begin-enum% e))
              (symbol% (begin-enum% e))
              (description% (begin-enum% e)))
      (dolist (value (values% e))
        (format sout "  .value(~a,~a)~%"
                (symbol% value)
                (value% value)))
      (format sout ";~%"))
    (format sout "#endif //ifdef ALL_ENUMS~%")))

(defun write-if-changed (code main-path app-relative)
  (let ((pn (make-pathname :name (pathname-name app-relative)
                           :type (pathname-type app-relative)
                           :directory '(:relative "include" "generated")
                           :defaults (pathname main-path))))
    (let ((data-in-file (when (probe-file pn)
                          (with-open-file (stream pn :direction :input)
                            (let ((data (make-string (file-length stream))))
                              (read-sequence data stream)
                              data)))))
      (unless (string= data-in-file code)
        (with-open-file (stream pn :direction :output :if-exists :supersede)
          (write-sequence code stream))))))

(defun generate-code (packages-to-create functions symbols classes enums main-path app-config)
  (let ((init-functions (generate-code-for-init-functions functions))
        (init-classes-and-methods (generate-code-for-init-classes-and-methods classes))
        (source-info (generate-code-for-source-info functions classes))
        (symbol-info (generate-code-for-symbols packages-to-create symbols))
        (enum-info (generate-code-for-enums enums)))
    (write-if-changed init-functions main-path (gethash :init_functions_inc_h app-config))
    (write-if-changed init-classes-and-methods main-path (gethash :init_classes_and_methods_inc_h app-config))
    (write-if-changed source-info main-path (gethash :source_info_inc_h app-config))
    (write-if-changed symbol-info main-path (gethash :symbols_scraped_inc_h app-config))
    (write-if-changed enum-info main-path (gethash :enum_inc_h app-config))
    #+(or)(generate-tags-file (merge-pathnames #P"TAGS" (translate-logical-pathname main-path)) tags)))
