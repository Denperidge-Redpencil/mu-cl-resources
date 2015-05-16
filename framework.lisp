(in-package :product-groups)

;;;;;;;;;;;;;;;;
;;;; error codes

(define-condition no-such-resource (error)
  ((description :initarg :description :reader description))
  (:documentation "Indicates the resource could not be found"))

(define-condition no-such-instance (error)
  ((type :initarg :type :reader target-type)
   (id :initarg :id :reader target-id)
   (resource :initarg :resource :reader resource))
  (:documentation "Indicates the resource could not be found"))

(define-condition simple-described-condition (error)
  ((description :initarg :description :reader description))
  (:documentation "Indicates an exception which should mainly be
    handled by its type and a base description."))

(define-condition incorrect-accept-header (simple-described-condition)
  ()
  (:documentation "Indicates a necessary accept header was not found."))

(define-condition incorrect-content-type (simple-described-condition)
  ()
  (:documentation "Indicates a necessary content-type header was not found."))

(define-condition no-type-in-data (error)
  ()
  (:documentation "Indicates no type property was found in the primary data"))

(define-condition id-in-data (error)
  ()
  (:documentation "Indicates an id property was found in the
    primary data whilst it was not expected."))

;;;;;;;;;;;;;;;;;;;;
;;;; Supporting code

(defun symbol-to-camelcase (content &key (cap-first nil))
  "builds a javascript variable from anything string-like"
  (format nil "~{~A~}"
          (let ((cap-next cap-first))
            (loop for char across (string-downcase (string content))
               if (char= char #\-)
               do (setf cap-next t)
               else collect (prog1
                                (if cap-next
                                    (char-upcase char)
                                    char)
                              (setf cap-next nil))))))

(defun merge-jsown-objects (a b)
  "Merges jsown objects a and b together.  Returns a new object
   which contains the merged contents."
  (let ((keys (union (jsown:keywords a) (jsown:keywords b) :test #'string=))
        (result (jsown:empty-object)))
    (loop for key in keys
       do (cond ((and (jsown:keyp a key)
                      (not (jsown:keyp b key)))
                 (setf (jsown:val result key)
                       (jsown:val a key)))
                ((and (not (jsown:keyp a key))
                      (jsown:keyp b key))
                 (setf (jsown:val result key)
                       (jsown:val b key)))
                (t (handler-case
                       (setf (jsown:val result key)
                             (merge-jsown-objects (jsown:val a key)
                                                  (jsown:val b key)))
                     (error () (setf (jsown:val result key)
                                     (jsown:val b key)))))))
    result))

(defun respond-not-found (&optional jsown-object)
  "Returns a not-found response.  The supplied jsown-object is
   merged with the response if it is supplied.  This allows you
   to extend the response and tailor it to your needs."
  (setf (hunchentoot:return-code*) hunchentoot:+http-not-found+)
  (merge-jsown-objects (jsown:new-js ("data" :null))
                       (or jsown-object (jsown:empty-object))))

(defun respond-not-acceptable (&optional jsown-object)
  "Returns a not-acceptable response.  The supplied jsown-object
   is merged with the response if it is supplied.  This allows
   you to extend the the response and tailor it to your needs."
  (setf (hunchentoot:return-code*) hunchentoot:+http-not-acceptable+)
  (merge-jsown-objects (jsown:new-js
                         ("errors" (jsown:new-js
                                     ("status" "Not Acceptable")
                                     ("code" "406"))))
                       (or jsown-object (jsown:empty-object))))

(defun respond-conflict (&optional jsown-object)
  "Returns a 409 Conflict response.  The supplied jsown-object
   is merged with the response if it is supplied.  This allows
   you to extend the the response and tailor it to your needs."
  (setf (hunchentoot:return-code*) hunchentoot:+http-conflict+)
  (merge-jsown-objects (jsown:new-js
                         ("errors" (jsown:new-js
                                     ("status" "Conflict")
                                     ("code" "409"))))
                       (or jsown-object (jsown:empty-object))))

(defun verify-json-api-content-type ()
  "Throws an error if the Content Type is not the required
   application/vnd.api+json Accept header."
  ;; NOTE: I'm not convinced that the server is required to check this
  ;;       this constraint.  It is not explicited in the spec.
  (unless (search "application/vnd.api+json"
                  (hunchentoot:header-in* :content-type))
    (error 'incorrect-content-type
           :description "application/vnd.api+json not found in Content-Type header")))

(defun verify-json-api-request-accept-header ()
  "Returns a 406 Not Acceptable status from the request (and
   returns nil) if the Accept header did not include the
   correct application/vnd.api+json Accept header."
  (unless (search "application/vnd.api+json"
                  (hunchentoot:header-in* :accept))
    (error 'incorrect-accept-header
           :description "application/vnd.api+json not found in Accept header")))

(defun verify-request-contains-type (obj)
  "Throws an error if the request does not contain a type."
  (unless (and (jsown:keyp obj "data")
               (jsown:keyp (jsown:val obj "data") "type"))
    (error 'no-type-in-data)))

(defun verify-request-contains-no-id (obj)
  "Throws an error if the request does not contain an id."
  (unless (and (jsown:keyp obj "data")
               (not (jsown:keyp (jsown:val obj "data") "id")))
    (error 'id-in-data)))

;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; parsing query results

(defun from-sparql (object)
  "Converts the supplied sparql value specification into a lisp value."
  (let ((type (intern (string-upcase (jsown:val object "type"))
                      :keyword))
        (value (jsown:val object "value")))
    (import-value-from-sparql-result type value object)))

(defgeneric import-value-from-sparql-result (type value object)
  (:documentation "imports the value from 'object' given its 'value'
   and 'type' to dispatch on.")
  (:method ((type (eql :uri)) value object)
    (declare (ignore object))
    value)
  (:method ((type (eql :literal)) value object)
    (declare (ignore object))
    value)
  (:method ((type (eql :typed-literal)) value object)
    (import-typed-literal-value-from-sparql-result
     (jsown:val object "datatype")
     value
     object)))

(defparameter *typed-literal-importers* (make-hash-table :test 'equal :synchronized t)
  "contains all convertors for typed-literal values coming from the database.")

(defmacro define-typed-literal-importer (type (&rest variables) &body body)
  "defines a new typed literal importer.  should receive value, object
   as variables."
  `(setf (gethash ,type *typed-literal-importers*)
         (lambda (,@variables)
           ,@body)))

(defun import-typed-literal-value-from-sparql-result (type value object)
  "imports a typed-literal-value from a sparql result."
  (funcall (gethash type *typed-literal-importers*)
           value object))

(define-typed-literal-importer "http://www.w3.org/2001/XMLSchema#decimal"
    (value object)
  (declare (ignore object))
  (read-from-string value))

(define-typed-literal-importer "http://www.w3.org/2001/XMLSchema#integer"
    (value object)
  (declare (ignore object))
  (parse-integer value))


;;;;;;;;;;;;;;;;;;;;;;;
;;;; defining resources

(defclass resource-slot ()
  ((json-key :initarg :json-key :reader json-key)
   (ld-property :initarg :ld-property :reader ld-property)
   (resource-type :initarg :resource-type :reader resource-type))
  (:documentation "Describes a single property of a resource."))

(defgeneric json-property-name (resource-slot)
  (:documentation "retrieves the name of the json property of the
   supplied resource-slot")
  (:method ((slot resource-slot))
    (symbol-to-camelcase (json-key slot))))

(defgeneric ld-property-list (slot)
  (:documentation "yields the ld-property as a list from the
   resource-slot")
  (:method ((slot resource-slot))
    (list (ld-property slot))))

(defclass has-many-link ()
  ((json-key :initarg :json-key :reader json-key)
   (resource :initarg :resource :reader ld-resource)
   (ld-link :initarg :via :reader ld-link))
  (:documentation "Describes a has-many link to another resource"))

(defclass resource ()
  ((ld-class :initarg :ld-class :reader ld-class)
   (ld-properties :initarg :ld-properties :reader ld-properties)
   (ld-resource-base :initarg :ld-resource-base :reader ld-resource-base)
   (json-type :initarg :json-type :reader json-type)
   (has-many-links :initarg :has-many :reader has-many-links)
   (request-path :initarg :request-path :reader request-path)))

(defparameter *resources* (make-hash-table)
  "contains all currently known resources")

(defun find-resource-by-path (path)
  "finds a resource based on the supplied request path"
  (maphash (lambda (name resource)
             (declare (ignore name))
             (when (string= (request-path resource) path)
               (return-from find-resource-by-path resource)))
           *resources*)
  (error 'no-such-resource
         :description (format nil "Path: ~A" path)))

(defun define-resource* (name &key ld-class ld-properties ld-resource-base has-many on-path)
  "defines a resource for which get and set requests exist"
  (let* ((properties (loop for (key type prop) in ld-properties
                        collect (make-instance 'resource-slot
                                               :json-key key
                                               :resource-type type
                                               :ld-property prop)))
         (has-many-links (mapcar (alexandria:curry #'make-instance 'has-many-link :resource)
                                 has-many))
         (resource (make-instance 'resource
                                  :ld-class ld-class
                                  :ld-properties properties
                                  :ld-resource-base ld-resource-base
                                  :has-many has-many-links
                                  :json-type (symbol-to-camelcase name :cap-first t)
                                  :request-path on-path)))
    (setf (gethash name *resources*) resource)))

(defmacro define-resource (name options &key class properties resource-base has-many on-path)
  (declare (ignore options))
  `(define-resource* ',name
       :ld-class ,class
       :ld-properties ,properties
       :ld-resource-base ,resource-base
       :has-many ,has-many
       :on-path ,on-path))

(defun property-paths-format-component (resource)
  (declare (ignore resource))
  "~{~&~4t~{~A~,^/~} ~A~,^;~}.")
(defun property-paths-content-component (resource json-input)
  (loop for slot
     in (ld-properties resource)
     append (list (ld-property-list slot)
                  (interpret-json-value
                   slot
                   (jsown:filter json-input
                                 "data"
                                 (json-property-name slot))))))


;;;;;;;;;;;;;;;;;;;;;;;
;;;; parsing user input

(defgeneric interpret-json-value (slot value)
  (:documentation "Interprets the supplied json value <value>
   given that it should be used for the supplied slot.  Yields a
   value which can be used in a query.")
  (:method ((slot resource-slot) value)
    (interpret-json-value-by-type slot (resource-type slot) value)))

(defgeneric interpret-json-value-by-type (slot type value)
  (:documentation "Interprets the supplied json value <value>
   given that it should be used for the supplied slot.  The type
   of the slot is supplied is the second parameter to dispatch on.")
  (:method ((slot resource-slot) type value)
    ;; (declare (ignore type))
    (s-from-json value))
  (:method ((slot resource-slot) (type (eql :url)) value)
    (s-url value)))


;;;;;;;;;;;;;;;;;;;;;;;;
;;;; call implementation

(defgeneric create-call (resource)
  (:documentation "implementation of the POST request which
    handles the creation of a resource.")
  (:method ((resource-symbol symbol))
    (create-call (gethash resource-symbol *resources*)))
  (:method ((resource resource))
    (let ((json-input (jsown:parse (post-body)))
          (uuid (princ-to-string (uuid:make-v4-uuid))))
      (insert *repository* ()
        (s+
         "GRAPH <http://mu.semte.ch/application/> { "
         "  ~A a ~A;"
         "  ~&~4tmu:uuid ~A;"
         (property-paths-format-component resource)
         "}")
        (s-url (format nil "~A~A"
                       (raw-content (ld-resource-base resource))
                       uuid))
        (ld-class resource)
        (s-str uuid)
        (property-paths-content-component resource json-input))
      (show-call resource uuid))))

(defgeneric update-call (resource uuid)
  (:documentation "implementation of the PUT request which
    handles the updating of a resource.")
  (:method ((resource-symbol symbol) uuid)
    (update-call (gethash resource-symbol *resources*) uuid))
  (:method ((resource resource) (uuid string))
    ;; ideally, we'd be a lot more prudent with deleting content
    (let ((json-input (jsown:parse (post-body))))
      (fuseki:query
       *repository*
       (format nil
               (s+
                "DELETE WHERE {"
                "  GRAPH <http://mu.semte.ch/application/> { "
                "    ?s mu:uuid ~A; "
                "    ~{~&~8t~{~A~,^/~} ~A~,^;~}."
                "  }"
                "}")
               (s-str uuid)
               (loop for slot
                  in (ld-properties resource)
                  for i from 0
                  append (list (ld-property-list slot)
                               (s-var (format nil "gensym~A" i))))))
      (insert *repository* ()
        (s+
         "GRAPH <http://mu.semte.ch/application/> { "
         "  ~A mu:uuid ~A; "
         (property-paths-format-component resource)
         "}")
        (s-url (s+ (raw-content (ld-resource-base resource)) uuid))
        (s-str uuid)
        (property-paths-content-component resource json-input)))
    (jsown:new-js
      ("success" :true))))

(defgeneric list-call (resource)
  (:documentation "implementation of the GET request which
   handles listing the whole resource")
  (:method ((resource-symbol symbol))
    (list-call (gethash resource-symbol *resources*)))
  (:method ((resource resource))
    (let ((uuids (jsown:filter
                  (query *repository*
                         (format nil
                                 (s+ "SELECT * WHERE {"
                                     "  GRAPH <http://mu.semte.ch/application/> {"
                                     "    ?s mu:uuid ?uuid;"
                                     "       a ~A."
                                     "  }"
                                     "}")
                                 (ld-class resource)))
                  map "uuid" "value")))
      (jsown:new-js ("data" (loop for uuid in uuids
                                     collect (jsown:val (show-call resource uuid)
                                                        "data")))))))

(defgeneric show-call (resource uuid)
  (:documentation "implementation of the GET request which
    handles the displaying of a single resource.")
  (:method ((resource-symbol symbol) uuid)
    (show-call (gethash resource-symbol *resources*) uuid))
  (:method ((resource resource) (uuid string))
    (let* ((solution
            (first
             (query *repository*
                    (format nil
                            (s+ "SELECT * WHERE {"
                                "  GRAPH <http://mu.semte.ch/application/> {"
                                "    ?s mu:uuid ~A; "
                                "    ~{~&~8t~{~A~,^/~} ~A~,^;~}."
                                "  }"
                                "}")
                            (s-str uuid)
                            (loop for slot in (ld-properties resource)
                               append (list (ld-property-list slot)
                                            (s-var (json-property-name slot))))))))
           (attributes (jsown:empty-object)))
      (unless solution
        (error 'no-such-instance
               :resource resource
               :id uuid
               :type (json-type resource)))
      (dolist (var (mapcar #'json-property-name
                           (ld-properties resource)))
        (setf (jsown:val attributes (symbol-to-camelcase var))
              (from-sparql (jsown:val solution var))))
      (jsown:new-js
        ("data" (jsown:new-js
                  ("attributes" attributes)
                  ("id" uuid)
                  ("type" (json-type resource))))))))

(defgeneric delete-call (resource uuid)
  (:documentation "implementation of the DELETE request which
   handles the deletion of a single resource")
  (:method ((resource-symbol symbol) uuid)
    (delete-call (gethash resource-symbol *resources*) uuid))
  (:method ((resource resource) (uuid string))
    (query *repository*
           (format nil
                   (s+ "DELETE WHERE {"
                       "  GRAPH <http://mu.semte.ch/application/> {"
                       "    ?s mu:uuid ~A;"
                       "       a ~A;"
                       "       ~{~&~8t~{~A~,^/~} ~A~,^;~}."
                       "  }"
                       "}")
                   (s-str uuid)
                   (ld-class resource)
                   (loop for slot in (ld-properties resource)
                      append (list (ld-property-list slot)
                                   (s-var (json-property-name slot))))))))
 

;;;;;;;;;;;;;;;;;;;
;;;; standard calls
(defcall :get (base-path)
  (list-call (find-resource-by-path base-path)))

(defcall :get (base-path id)
  (handler-case
      (progn
        (verify-json-api-request-accept-header)
        (show-call (find-resource-by-path base-path) id))
    (no-such-resource ()
      (respond-not-found))
    (no-such-instance ()
      (respond-not-found))
    (incorrect-accept-header (condition)
      (respond-not-acceptable (jsown:new-js
                                ("errors" (jsown:new-js
                                            ("title" (description condition)))))))))

(defcall :post (base-path)
  (let ((body (jsown:parse (post-body))))
    (handler-case
        (progn
          (verify-json-api-request-accept-header)
          (verify-json-api-content-type)
          (verify-request-contains-type body)
          (verify-request-contains-no-id body)
          (create-call (find-resource-by-path base-path)))
      (incorrect-accept-header (condition)
        (respond-not-acceptable (jsown:new-js
                                  ("errors" (jsown:new-js
                                              ("title" (description condition)))))))
      (incorrect-content-type (condition)
        (respond-not-acceptable (jsown:new-js
                                  ("errors" (jsown:new-js
                                              ("title" (description condition)))))))
      (no-type-in-data ()
        (respond-conflict (jsown:new-js
                            ("errors" (jsown:new-js
                                        ("title" "No type found in primary data."))))))
      (id-in-data ()
        (respond-conflict (jsown:new-js
                            ("errors" (jsown:new-js
                                        ("title" "Not allow to supply id in primary data.")))))))))

(defcall :put (base-path id)
  (update-call (find-resource-by-path base-path) id))

(defcall :delete (base-path id)
  (delete-call (find-resource-by-path base-path) id))
