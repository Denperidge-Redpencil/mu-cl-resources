(in-package :mu-cl-resources)

;;;;
;; item specs

(defclass item-spec ()
  ((uuid :accessor uuid :initarg :uuid)
   (type :accessor resource-name :initarg :type)
   (related-items :accessor related-items-table
                  :initform (make-hash-table :test 'equal)
                  :initarg :related-items))
  (:documentation "Represents an item that should be loaded."))

(defun make-item-spec (&key uuid type)
  "Creates a new item-spec instance."
  (make-instance 'item-spec :type type :uuid uuid))

(defun item-spec-hash-key (item-spec)
  "Creates a key which can be compared through #'equal."
  (list (resource-name item-spec) (uuid item-spec)))

(defmethod resource ((spec item-spec))
  (find-resource-by-name (resource-name spec)))

(defgeneric related-items (item-spec relation)
  (:documentation "Returns the related items for the given relation")
  (:method ((item-spec item-spec) relation)
    (gethash relation (related-items-table item-spec) nil)))


;;;;;;;;;;;;;;;;;;;;;;
;; call implementation

(defgeneric create-call (resource)
  (:documentation "implementation of the POST request which
    handles the creation of a resource.")
  (:method ((resource-symbol symbol))
    (create-call (find-resource-by-name resource-symbol)))
  (:method ((resource resource))
    (let* ((jsown:*parsed-null-value* :null)
           (json-input (jsown:parse (post-body)))
           (uuid (mu-support:make-uuid)) 
           (resource-uri (s-url (format nil "~A~A"
                                        (raw-content (ld-resource-base resource))
                                        uuid))))
      (sparql:insert-triples
       `((,resource-uri ,(s-prefix "a") ,(ld-class resource))
         (,resource-uri ,(s-prefix "mu:uuid") ,(s-str uuid))
         ,@(loop for (predicates object)
              in (attribute-properties-for-json-input resource json-input)
              unless (eq object :null)
              collect `(,resource-uri ,@predicates ,object))))
      (setf (hunchentoot:return-code*) hunchentoot:+http-created+)
      (setf (hunchentoot:header-out :location)
            (construct-resource-item-path resource uuid))
      (when (and (jsown:keyp json-input "data")
                 (jsown:keyp (jsown:val json-input "data") "relationships"))
        (loop for relation in (jsown:keywords (jsown:filter json-input "data" "relationships"))
           if (jsown:keyp (jsown:filter json-input "data" "relationships" relation)
                          "data")
           do
             (update-resource-relation resource uuid relation
                                       (jsown:filter json-input
                                                     "data" "relationships" relation "data"))))
      (jsown:new-js ("data" (retrieve-item resource uuid))))))


(defun find-resource-for-uuid (resource uuid)
  "Retrieves the resource hich specifies the supplied UUID in the database."
  (let ((result (sparql:select (s-var "s")
                               (format nil (s+ "?s mu:uuid ?uuid. "
                                               "FILTER(~A = str(?uuid))")
                                       (s-str uuid)))))
    (unless result
      (error 'no-such-instance
             :resource resource
             :id uuid
             :type (json-type resource)))
    (jsown:filter (first result) "s" "value")))

(defgeneric update-call (resource uuid)
  (:documentation "implementation of the PUT request which
    handles the updating of a resource.")
  (:method ((resource-symbol symbol) uuid)
    (update-call (find-resource-by-name resource-symbol) uuid))
  (:method ((resource resource) (uuid string))
    (let* ((jsown:*parsed-null-value* :null)
           (json-input (jsown:parse (post-body)))
           (attributes (jsown:filter json-input "data" "attributes"))
           (uri (s-url (find-resource-for-uuid resource uuid))))
      (sparql:with-query-group
        (let ((delete-vars (loop for key in (jsown:keywords attributes)
                              for i from 0
                              collect (s-var (format nil "gensym~A" i)))))
          (sparql:delete-triples
           (loop for key in (jsown:keywords attributes)
              for slot = (resource-slot-by-json-key resource key)
              for s-var in delete-vars
              collect `(,uri ,@(ld-property-list slot) ,s-var))))
        (sparql:insert-triples
         (loop for key in (jsown:keywords attributes)
            for slot = (resource-slot-by-json-key resource key)
            for value = (if (eq (jsown:val attributes key) :null)
                            :null
                            (interpret-json-value slot (jsown:val attributes key)))
            for property-list = (ld-property-list slot)
            unless (eq value :null)
            collect
              `(,uri ,@property-list ,value))))
      (when (and (jsown:keyp json-input "data")
                 (jsown:keyp (jsown:val json-input "data") "relationships"))
        (loop for relation in (jsown:keywords (jsown:filter json-input "data" "relationships"))
           if (jsown:keyp (jsown:filter json-input "data" "relationships" relation)
                          "data")
           do
             (update-resource-relation resource uuid relation
                                       (jsown:filter json-input
                                                     "data" "relationships" relation "data")))))
    (respond-no-content)))

(defgeneric update-resource-relation (resource uuid relation resource-specification)
  (:documentation "updates the specified relation with the given specification.")
  (:method ((resource resource) uuid (relation string) resource-specification)
    (update-resource-relation resource
                              uuid
                              (find-link-by-json-name resource relation)
                              resource-specification))
  (:method ((resource resource) uuid (link has-one-link) resource-specification)
    (flet ((delete-query (resource-uri link-uri)
             (sparql:delete-triples
              `((,resource-uri ,@link-uri ,(s-var "s")))))
           (insert-query (resource-uri link-uri new-linked-uri)
             (sparql:insert-triples
              `((,resource-uri ,@link-uri ,new-linked-uri)))))
      (let ((linked-resource (referred-resource link))
            (resource-uri (find-resource-for-uuid resource uuid)))
        (if resource-specification
            ;; update content
            (let* ((new-linked-uuid (jsown:val resource-specification "id"))
                   (new-linked-uri (find-resource-for-uuid linked-resource new-linked-uuid)))
              (sparql:with-query-group
                (delete-query (s-url resource-uri)
                              (ld-property-list link))
                (insert-query (s-url resource-uri)
                              (ld-property-list link)
                              (s-url new-linked-uri))))
            ;; delete content
            (delete-query (s-url resource-uri)
                          (ld-property-list link))))))
  (:method ((resource resource) uuid (link has-many-link) resource-specification)
    (flet ((delete-query (resource-uri link-uri)
             (sparql:delete-triples
              `((,resource-uri ,@link-uri ,(s-var "s")))))
           (insert-query (resource-uri link-uri new-linked-uris)
             (sparql:insert-triples
              (loop for new-link-uri in new-linked-uris
                 collect
                   `(,resource-uri ,@link-uri ,new-link-uri)))))
      (let ((linked-resource (referred-resource link))
            (resource-uri (find-resource-for-uuid resource uuid)))
        (if resource-specification
            ;; update content
            (let* ((new-linked-uuids (jsown:filter resource-specification map "id"))
                   (new-linked-resources (mapcar (alexandria:curry #'find-resource-for-uuid
                                                                   linked-resource)
                                                 new-linked-uuids)))
              (sparql:with-query-group
                (delete-query (s-url resource-uri)
                              (ld-property-list link))
                (insert-query (s-url resource-uri)
                              (ld-property-list link)
                              (mapcar #'s-url new-linked-resources))))
            ;; delete content
            (delete-query (s-url resource-uri)
                          (ld-property-list link)))))))

(defgeneric list-call (resource)
  (:documentation "implementation of the GET request which
   handles listing the whole resource")
  (:method ((resource-symbol symbol))
    (list-call (find-resource-by-name resource-symbol)))
  (:method ((resource resource))
    (paginated-collection-response
     :resource resource
     :sparql-body (filter-body-for-search
                   :sparql-body  (format nil "?s mu:uuid ?uuid; a ~A."
                                         (ld-class resource))
                   :source-variable (s-var "s")
                   :resource resource))))

(defgeneric show-call (resource uuid)
  (:documentation "implementation of the GET request which
    handles the displaying of a single resource.")
  (:method ((resource-symbol symbol) uuid)
    (show-call (find-resource-by-name resource-symbol) uuid))
  (:method ((resource resource) (uuid string))
    (multiple-value-bind (data included-items)
        (retrieve-item resource uuid)
      (if (eq data :null)
          (error 'no-such-instance
                 :resource resource
                 :id uuid
                 :type (json-type resource))
          (let ((response
                 (jsown:new-js
                   ("data" data)
                   ("links" (jsown:new-js
                              ("self" (construct-resource-item-path resource uuid)))))))
            (when included-items
              (setf (jsown:val response "included") included-items))
            response)))))

(defun retrieve-item-by-spec (spec)
  "Retrieves an item from its specification.
   '(:type catalog :id \"ae12ee\")"
  (retrieve-item (resource-name spec) (uuid spec)))

(defun item-spec-to-jsown (item-spec)
  "Returns the jsown representation of the attributes and
   non-filled relationships of item-spec.  This is the default
   way of fetching the database contents of a single item."
  (handler-bind
      ((no-such-instance (lambda () :null)))
    (let* ((resource (resource item-spec))
           (uuid (uuid item-spec))
           (resource-url
            ;; we search for a resource separately as searching it
            ;; in one query is redonculously slow.  in the order of
            ;; seconds for a single solution.
            (find-resource-for-uuid resource uuid))
           (solution
            ;; simple attributes
            (first
             (sparql:select
              "*"
              (format nil
                      "~{~&OPTIONAL {~A ~{~A~,^/~} ~A.}~}"
                      (loop for slot in (ld-properties resource)
                         when (single-value-slot-p slot)
                         append (list (s-url resource-url)
                                      (ld-property-list slot)
                                      (s-var (sparql-variable-name slot))))))))
           (attributes (jsown:empty-object)))
      ;; read simple attributes from sparql query
      (loop for slot in (ld-properties resource)
         for variable-name = (sparql-variable-name slot)
         unless (single-value-slot-p slot)
         do
           (setf (jsown:val solution variable-name)
                 (mapcar (lambda (solution) (jsown:val solution variable-name))
                         (sparql:select "*"
                                        (format nil "~A ~{~A~,^/~} ~A."
                                                (s-url resource-url)
                                                (ld-property-list slot)
                                                (s-var variable-name))))))
      ;; read extended variables through separate sparql query
      (loop for property in (ld-properties resource)
         for sparql-var = (sparql-variable-name property)
         for json-var = (json-property-name property)
         if (jsown:keyp solution sparql-var)
         do
           (setf (jsown:val attributes json-var)
                 (from-sparql (jsown:val solution sparql-var) (resource-type property))))
      ;; build response data object
      (let ((relationships-object (jsown:empty-object)))
        (loop for link in (all-links resource)
           do
             (setf (jsown:val relationships-object (json-key link))
                   (build-relationships-object item-spec link)))
        (jsown:new-js
          ("attributes" attributes)
          ("id" uuid)
          ("type" (json-type resource))
          ("relationships" relationships-object))))))

(defun retrieve-item (resource uuid &key included)
  "Returns (values item-json included-items)
   item-json contains the description of the specified item with
     necessary links from <included>.
   included-items is an alist with the json name of a realtion as
     its keys and a list of item specifications as its values.
     (eg: '((\"catalogs\" (:type catalog :id \"ae12ee\")
                          (:type catalog :id \"123456\"))
            (\"users\" (:type user :id \"42\")
                       (:type user :id \"1337\"))))

   The included key contains a list of keys which aught to be
   retrieved in the included portion of the response.  This
   ensures the included-items portion is returned, but also
   ensures that the identifiers/types are included inline with
   the links response."
  (declare (ignore included))
  (handler-bind
      ((no-such-instance (lambda () :null)))
    (multiple-value-bind (data-item-specs included-item-specs)
        (augment-data-with-attached-info
         (list (make-item-spec :uuid uuid
                               :type (resource-name resource))))
      (values (item-spec-to-jsown (first data-item-specs))
              (mapcar #'item-spec-to-jsown included-item-specs)))))

(defgeneric build-relationships-object (item-spec link)
  (:documentation "Returns the content of one of the relationships based
   on the type of relation, and whether or not the relationship should
   be inlined.  Values to inline should be included directly.")
  (:method ((item-spec item-spec) (link has-link))
    (let ((links-object (build-links-object (resource item-spec)
                                            (uuid item-spec)
                                            link)))
      (multiple-value-bind (included-items included-items-p)
          (related-items item-spec link)
        (if included-items-p
            (jsown:new-js ("links" links-object)
                          ("data" (mapcar #'jsown-inline-item-spec included-items)))
            (jsown:new-js ("links" links-object)))))))

(defgeneric jsown-inline-item-spec (item-spec)
  (:documentation "Yields the inline id/type to indicate a particular
   resource")
  (:method ((item-spec item-spec))
    (jsown:new-js ("type" (json-type (resource item-spec)))
                  ("id" (uuid item-spec)))))

  ;; TODO probably not used anymore
(defgeneric build-data-object-for-included-relation (link items)
  (:documentation "Builds the data object for an included relation.
   This object contains the references to the relationship.
   <items> should be a list of item-spec instances.")
  (:method ((link has-one-link) (items (eql nil)))
    :null)
  (:method ((link has-one-link) items)
    (jsown-inline-item-spec (first items)))
  (:method ((link has-many-link) items)
    (mapcar #'jsown-inline-item-spec items)))

(defgeneric build-links-object (resource identifier link)
  (:documentation "Builds the json object which represents the link
    in a json object.")
  (:method ((resource resource) identifier (link has-link))
    (jsown:new-js ("self" (format nil "/~A/~A/links/~A"
                                  (request-path resource)
                                  identifier
                                  (request-path link)))
                  ("related" (format nil "/~A/~A/~A"
                                     (request-path resource)
                                     identifier
                                     (request-path link))))))

(defgeneric delete-call (resource uuid)
  (:documentation "implementation of the DELETE request which
   handles the deletion of a single resource")
  (:method ((resource-symbol symbol) uuid)
    (delete-call (find-resource-by-name resource-symbol) uuid))
  (:method ((resource resource) (uuid string))
    (let (relation-content)
      (loop for slot in (ld-properties resource)
         do (push (list (ld-property-list slot)
                        (s-var (sparql-variable-name slot)))
                  relation-content))
      (loop for link in (all-links resource)
         do (push (list (ld-property-list link)
                        (s-var (sparql-variable-name link)))
                  relation-content))
      (setf relation-content (reverse relation-content))
      (sparql:delete
       (apply #'concatenate 'string
              (loop for triple-clause
                 in
                   `((,(s-var "s") ,(s-prefix "mu:uuid") ,(s-str uuid))
                     (,(s-var "s") ,(s-prefix "a") ,(ld-class resource))
                     ,@(loop for (property-list value) in relation-content
                          collect `(,(s-var "s") ,@property-list ,value)))
                 for (subject predicate object) = triple-clause
                 collect (if (s-inv-p predicate)
                             (format nil "~4t~A ~A ~A.~%"
                                     object (s-inv predicate) subject)
                             (format nil "~4t~A ~A ~A.~%"
                                     subject predicate object))))
       (concatenate 'string
                    (format nil "~{~&~4t~{~A ~A ~A~}.~%~}"
                            `((,(s-var "s") ,(s-prefix "mu:uuid") ,(s-str uuid))
                              (,(s-var "s") ,(s-prefix "a") ,(ld-class resource))))
                    (format nil "~{~&~4tOPTIONAL {~{~A ~A ~A~}.}~%~}"
                            (loop for (property-list value) in relation-content
                               if (s-inv-p (first property-list))
                               collect `(,value ,(s-inv (first property-list)) ,(s-var "s"))
                               else
                               collect `(,(s-var "s") ,(first property-list) ,value))))))
    (respond-no-content)))

(defgeneric show-relation-call (resource id link)
  (:documentation "implementation of the GET request which handles
    the listing of a relation.")
  (:method ((resource-symbol symbol) id link)
    (show-relation-call (find-resource-by-name resource-symbol) id link))
  (:method ((resource resource) id (link has-one-link))
    (let ((item-spec (first (retrieve-relation-items resource id link))))
      (jsown:new-js
        ("data" (if item-spec
                    (retrieve-item-by-spec item-spec)
                    :null))
        ("links" (build-links-object resource id link)))))
  (:method ((resource resource) id (link has-many-link))
    (paginated-collection-response
     :resource (referred-resource link)
     :sparql-body (filter-body-for-search
                   :sparql-body (format nil
                                        (s+ "~A ~{~A~,^/~} ?resource. "
                                            "?resource mu:uuid ?uuid.")
                                        (s-url (find-resource-for-uuid resource id))
                                        (ld-property-list link))
                   :source-variable (s-var "resource")
                   :resource (referred-resource link))
     :link-defaults (build-links-object resource id link))))

(defgeneric retrieve-relation-items (resource id link)
  (:documentation "retrieves the item descriptions of the items
    which are connected to <resource> <id> through link <link>.
    This yields the high-level description of the items, not
    their contents.
    Note that this method does not support pagination.")
  (:method ((resource-symbol symbol) id link)
    (retrieve-relation-items (find-resource-by-name resource-symbol) id link))
  (:method ((resource resource) id (link string))
    (retrieve-relation-items resource id (find-link-by-json-name resource link)))
  (:method ((resource resource) id (link has-one-link))
    (let ((query-results
           (first (sparql:select (s-var "uuid")
                                 (format nil (s+ "~A ~{~A~,^/~} ?resource. "
                                                 "?resource mu:uuid ?uuid. ")
                                         (s-url (find-resource-for-uuid resource id))
                                         (ld-property-list link)))))
          (linked-resource (resource-name (referred-resource link))))
      (and query-results
           (list
            (make-item-spec :type linked-resource
                            :uuid (jsown:filter query-results "uuid" "value"))))))
  (:method ((resource resource) id (link has-many-link))
    (let ((query-results
           (sparql:select (s-var "uuid")
                          (format nil (s+ "~A ~{~A~,^/~} ?resource. "
                                          "?resource mu:uuid ?uuid. ")
                                  (s-url (find-resource-for-uuid resource id))
                                  (ld-property-list link))))
          (linked-resource (resource-name (referred-resource link))))
      (loop for uuid in (jsown:filter query-results map "uuid" "value")
         collect
           (make-item-spec :type linked-resource :uuid uuid)))))

(defgeneric patch-relation-call (resource id link)
  (:documentation "implementation of the PATCH request which
    handles the updating of a relation.")
  (:method ((resource-symbol symbol) id link)
    (patch-relation-call (find-resource-by-name resource-symbol) id link))
  (:method ((resource resource) id (link has-one-link))
    (flet ((delete-query (resource-uri link-uri)
             (sparql:delete-triples
              `((,resource-uri ,@link-uri ,(s-var "s")))))
           (insert-query (resource-uri link-uri new-linked-uri)
             (sparql:insert-triples
              `((,resource-uri ,@link-uri ,new-linked-uri)))))
      (let ((body (jsown:parse (post-body)))
            (linked-resource (referred-resource link))
            (resource-uri (find-resource-for-uuid resource id))
            (link-path (ld-property-list link)))
        (if (jsown:val body "data")
            ;; update content
            (let* ((new-linked-uuid (jsown:filter body "data" "id"))
                   (new-linked-uri (find-resource-for-uuid linked-resource new-linked-uuid)))
              (sparql:with-query-group
                (delete-query (s-url resource-uri) link-path)
                (insert-query (s-url resource-uri) link-path
                              (s-url new-linked-uri))))
            ;; delete content
            (delete-query (s-url resource-uri) link-path))))
    (respond-no-content))
  (:method ((resource resource) id (link has-many-link))
    (flet ((delete-query (resource-uri link-uri)
             (sparql:delete-triples
              `((,resource-uri ,@link-uri ,(s-var "s")))))
           (insert-query (resource-uri link-uri new-linked-uris)
             (sparql:insert-triples
              (loop for new-uri in new-linked-uris
                 collect `(,resource-uri ,@link-uri ,new-uri)))))
      (let ((body (jsown:parse (post-body)))
            (linked-resource (referred-resource link))
            (resource-uri (find-resource-for-uuid resource id))
            (link-path (ld-property-list link)))
        (if (jsown:val body "data")
            ;; update content
            (let* ((new-linked-uuids (jsown:filter body "data" map "id"))
                   (new-linked-resources (mapcar (alexandria:curry #'find-resource-for-uuid
                                                                   linked-resource)
                                                 new-linked-uuids)))
              (delete-query (s-url resource-uri) link-path)
              (insert-query (s-url resource-uri)
                            link-path
                            (mapcar #'s-url new-linked-resources)))
            ;; delete content
            (delete-query (s-url resource-uri)
                          link-path))))
    (respond-no-content)))

(defgeneric delete-relation-call (resource id link)
  (:documentation "Performs a delete call on a relation, thereby
    removing a set of linked resources.")
  (:method ((resource resource) id (link has-many-link))
    (let* ((linked-resource (referred-resource link))
           (resources (mapcar
                       (alexandria:curry #'find-resource-for-uuid
                                         linked-resource)
                       (remove-if-not #'identity
                                      (jsown:filter (jsown:parse (post-body))
                                                    "data" map "id")))))
      (when resources
        (sparql:delete-triples
         (loop for resource in resources
            collect
              `(,(s-url (find-resource-for-uuid resource id))
                 ,@(ld-property-list link)
                 ,resource)))))
    (respond-no-content)))

(defgeneric add-relation-call (resource id link)
  (:documentation "Performs the addition call on a relation, thereby
    adding a set of linked resources.")
  (:method ((resource resource) id (link has-many-link))
    (let* ((linked-resource (referred-resource link))
           (resources (mapcar
                       (alexandria:curry #'find-resource-for-uuid
                                         linked-resource)
                       (remove-if-not #'identity
                                      (jsown:filter (jsown:parse (post-body))
                                                    "data" map "id")))))
      (when resources
        (let ((source-url (find-resource-for-uuid resource id))
              (properties (ld-property-list link)))
          (sparql:insert-triples
           (loop for resource in resources
              collect
                `(,(s-url source-url) ,@properties ,(s-url resource)))))))
    (respond-no-content)))

;;;;
;; support for 'included'
;;
;; - Objects which are to be included follow the following structure:
;;   > (list :type 'catalog :id 56E6925A193F022772000001)
;; - relation-spec follows the following structure (books.author):
;;   > (list "books" "author")

(defun augment-data-with-attached-info (item-specs)
  "Augments the current item-specs with extra information on which
   attached items to include in the relationships.
   Returns (values data-item-specs included-item-specs).
   data-item-specs: the current items of the main data portion.
   included-item-specs: items in the included portion of the
   response."
  (let ((included-items-store (make-included-items-store-from-list item-specs)))
    (dolist (included-spec (extract-included-from-request))
      (include-items-for-included included-items-store item-specs included-spec))
    (let ((items (included-items-store-list-items included-items-store)))
      (values (loop for item in items
                 if (find item item-specs)
                 collect item)
              (loop for item in items
                 unless (find item item-specs)
                 collect item)))))

(defstruct included-items-store
  (table (make-hash-table :test 'equal)))

(defun included-items-store-contains (store item-spec)
  "Returns item-spec iff <item-spec> is included in <store>.
   Returns nil otherwise"
  (gethash (item-spec-hash-key item-spec) (included-items-store-table store)))

(defgeneric included-items-store-ensure (store ensured-content)
  (:documentation "Ensures <item-spec> is contained in <store>.
   If an <item-spec> which matches the same item-spec-hash-key is
   already stored, then the one from the store is returned,
   otherwise, the new ensured-content is returned.")
  (:method ((store included-items-store) (item-spec item-spec))
    (let ((table (included-items-store-table store))
          (key (item-spec-hash-key item-spec)))
      (or (gethash key table)
          (setf (gethash key table) item-spec))))
  (:method ((store included-items-store) (new-items included-items-store))
    (loop for item-spec in (included-items-store-list-items new-items)
       collect
         (included-items-store-ensure store item-spec))))

(defgeneric included-items-store-subtract (store subtracted-content)
  (:documentation "Subtracts <subtracted-content> from <store>.")
  (:method ((store included-items-store) (item-spec item-spec))
    (remhash (item-spec-hash-key item-spec)
             (included-items-store-table store)))
  (:method ((store included-items-store) (subtracted-store included-items-store))
    (mapcar (alexandria:curry #'included-items-store-subtract store)
            (included-items-store-list-items subtracted-store))))

(defun included-items-store-list-items (store)
  "Retrieves all items in the included-items-store"
  (loop for item-spec being the hash-values of (included-items-store-table store)
     collect item-spec))

(defun make-included-items-store-from-list (items-list)
  "Constructs a new included items store containing the list of
   items in <items-list>."
  (let ((store (make-included-items-store)))
    (mapcar (alexandria:curry #'included-items-store-ensure store)
            items-list)
    store))

(defun include-items-for-included (included-items-store item-specs included-spec)
  "Traverses the included-spec with the items in item-specs and ensures
   they're recursively included.  The item-specs also get to know which
   items have to be added."
  (dolist (item item-specs)
    (let (linked-items)
      ;; fill in current path
      (setf linked-items
            (union linked-items
               (include-items-for-single-included included-items-store item
                                                  (first included-spec))))
      ;; traverse included-spec path
      (when (rest included-spec)
        (include-items-for-included included-items-store linked-items
                                    (rest included-spec))))))

(defun include-items-for-single-included (included-items-store item-spec relation-string)
  "Adds the items which are linked to item-spec by relation included-spec
   to included-items-store.  Returns the list of items which are linked
   through item-spec."
  (let* ((resource (resource item-spec))
         (uuid (uuid item-spec))
         (relation (find-resource-link-by-json-key resource relation-string))
         (target-type (resource-name relation))
         (related-objects
          (loop for new-uuid
             in (jsown:filter
                 (sparql:select (s-var "target")
                                (format nil (s+ "?s mu:uuid ~A. "
                                                "?s ~{~A/~}mu:uuid ?target. ")
                                        (s-str uuid)
                                        (ld-property-list relation)))
                 map "target" "value")
             collect (included-items-store-ensure included-items-store
                                                  (make-item-spec :uuid new-uuid
                                                                  :type target-type)))))
    (setf (gethash relation (related-items-table item-spec))
          related-objects)
    related-objects))

(defun included-for-request (current-items)
  "Returns the list containing all included objects for the currently
   returned items and the current set of responses"
  (let ((current-items-store (make-included-items-store))
        (included-items-store (make-included-items-store)))
    ;; drop current-items in a store
    (dolist (item current-items)
      (included-items-store-ensure
       current-items-store
       (make-item-spec :uuid (jsown:val item "id")
                       :type (resource-name (find-resource-by-path (jsown:val item "type"))))))
    ;; put all included items in the included-items-store
    (dolist (relation-spec (extract-included-from-request))
      (augment-included included-items-store current-items-store relation-spec))
    ;; subtract items which were already in the included-items-store
    ;; as they will already be inlined in the main response
    (included-items-store-subtract included-items-store current-items-store)
    ;; return the /list/ of new items
    (included-items-store-list-items included-items-store)))

(defun extract-included-from-request ()
  "Extracts the filters from the request.  The result is a list
   containing the :components and :search key.  The :components
   key includes a left-to-right specification of the strings
   between brackets.  The :search contains the content for that
   specification."
  (let ((include-parameter
         (assoc "include" (hunchentoot:get-parameters*) :test #'string=)))
    (and include-parameter
         (mapcar (alexandria:curry #'split-sequence:split-sequence #\.)
                 (split-sequence:split-sequence #\, (cdr include-parameter))))))

(defun augment-included (current-included source-objects relation-spec)
  "Adds all objects which match <relation> starting from <source-objects>
   to <relation-spec>."
  (if (not relation-spec)
      current-included
      (let ((items-to-ensure (find-included-items-by-relation source-objects
                                                              (first relation-spec))))
        (included-items-store-ensure current-included items-to-ensure)
        (augment-included current-included items-to-ensure (rest relation-spec))
        current-included)))

(defun find-included-items-by-relation (source-objects relation-string)
  "Finds the included items by a specific relation string for each of the source-objects.
   The items which are to be included are returned in the store which is returned."
  (let ((new-items (make-included-items-store)))
    (dolist (item (included-items-store-list-items source-objects))
      (let* ((resource (resource item))
             (relation (find-resource-link-by-json-key resource relation-string))
             (target-type (resource-name relation)))
        (dolist (new-uuid
                  (jsown:filter
                   (sparql:select (s-var "target")
                                  (format nil (s+ "?s mu:uuid ~A. "
                                                  "?s ~{~A/~}mu:uuid ?target. ")
                                          (s-str (uuid item))
                                          (ld-property-list relation)))
                   map "target" "value"))
          (included-items-store-ensure new-items
                                       (make-item-spec :uuid new-uuid
                                                       :type target-type)))))
    new-items))
