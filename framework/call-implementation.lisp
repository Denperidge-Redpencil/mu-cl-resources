(in-package :mu-cl-resources)


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
      (declare (ignore included-items))
      (if (eq data :null)
          (error 'no-such-instance
                 :resource resource
                 :id uuid
                 :type (json-type resource))
          (jsown:new-js
            ("data" data)
            ("links" (jsown:new-js
                       ("self" (construct-resource-item-path resource uuid)))))))))

(defun retrieve-item-by-spec (spec)
  "Retrieves an item from its specification.
   '(:type catalog :id \"ae12ee\")"
  (retrieve-item (getf spec :type) (getf spec :id)))

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
    (let* ((resource-url
            ;; we search for a resource separately as searching it
            ;; in one query is redonculously slow.  in the order of
            ;; seconds for a single solution.
            (find-resource-for-uuid resource uuid))
           (solution (first
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
      (loop for property in (ld-properties resource)
         for sparql-var = (sparql-variable-name property)
         for json-var = (json-property-name property)
         if (jsown:keyp solution sparql-var)
         do
           (setf (jsown:val attributes json-var)
                 (from-sparql (jsown:val solution sparql-var) (resource-type property))))
      (let* ((resp-data (jsown:new-js
                          ("attributes" attributes)
                          ("id" uuid)
                          ("type" (json-type resource))
                          ("relationships" (jsown:empty-object))))
             included-items)
        (loop for link in (all-links resource)
           do
             (multiple-value-bind (relationship-object new-included-items)
                 (build-relationships-object resource uuid link t)
               (setf (jsown:val (jsown:val resp-data "relationships") (json-key link))
                     relationship-object)
               (setf (getf included-items (json-key link)) new-included-items)))
        (values resp-data included-items)))))

(defgeneric build-relationships-object (resource uuid link included-p)
  (:documentation "Returns the content of one of the relationships based
   on the type of relation, and whether or not the relationship should
   be inlined.  Values to inline should be included directly.")
  (:method ((resource resource) uuid (link has-link) (included-p (eql nil)))
    (jsown:new-js ("links" (build-links-object resource uuid link))))
  (:method ((resource resource) uuid (link has-link) (included-p (eql t)))
    (let ((related-items (retrieve-relation-items resource uuid link)))
      (values
       (jsown:new-js ("links" (build-links-object resource uuid link))
                     ("data" (build-data-object-for-included-relation link related-items)))
       related-items))))

(defgeneric build-data-object-for-included-relation (link items)
  (:documentation "Builds the data object for an included relation.
   This object contains the references to the relationship.")
  (:method ((link has-one-link) (items (eql nil)))
    :null)
  (:method ((link has-one-link) items)
    (let ((item-spec (first items)))
      (jsown:new-js ("type" (json-type (find-resource-by-name (getf item-spec :type))))
                    ("id" (getf item-spec :id)))))
  (:method ((link has-many-link) items)
    (loop for item-spec in items
       collect
         (jsown:new-js ("type" (json-type (find-resource-by-name (getf item-spec :type))))
                       ("id" (getf item-spec :id))))))

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
           `((:type ,linked-resource :id ,(jsown:filter query-results "uuid" "value"))))))
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
           `(:type ,linked-resource :id ,uuid)))))

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

(defstruct included-items-store
  (table (make-hash-table :test 'equal)))

(defun included-items-store-contains (store item-spec)
  "Returns non-nil ff <item-spec> is included in <store>."
  (gethash item-spec (included-items-store-table store)))

(defgeneric included-items-store-ensure (store ensured-content)
  (:documentation "Ensures <item-spec> is contained in <store>.")
  (:method ((store included-items-store) (item-spec list))
    (setf (gethash item-spec (included-items-store-table store)) t))
  (:method ((store included-items-store) (new-items included-items-store))
    (dolist (item (included-items-store-list-items new-items))
      (included-items-store-ensure store item))))

(defgeneric included-items-store-subtract (store subtracted-content)
  (:documentation "Subtracts <subtracted-content> from <store>.")
  (:method ((store included-items-store) (item-spec list))
    (remhash item-spec (included-items-store-table store)))
  (:method ((store included-items-store) (subtracted-store included-items-store))
    (mapcar (alexandria:curry #'included-items-store-subtract store)
            (included-items-store-list-items subtracted-store))))

(defun included-items-store-list-items (store)
  "Retrieves all items in the included-items-store"
  (loop for key being the hash-keys of (included-items-store-table store)
     collect key))

(defun make-included-items-store-from-list (items-list)
  "Constructs a new included items store containing the list of
   items in <items-list>."
  (let ((store (make-included-items-store)))
    (mapcar (alexandria:curry #'included-items-store-ensure store)
            items-list)
    store))

(defun included-for-request (current-items)
  "Returns the list containing all included objects for the currently
   returned items and the current set of responses"
  (let ((current-items-store (make-included-items-store))
        (included-items-store (make-included-items-store)))
    (dolist (item current-items)
      (included-items-store-ensure
       current-items-store
       (list :type (resource-name (find-resource-by-path (jsown:val item "type")))
             :id (jsown:val item "id"))))
    (dolist (relation-spec (extract-included-from-request))
      (augment-included included-items-store current-items-store relation-spec))
    (included-items-store-subtract included-items-store current-items-store)
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
      (let ((item-type (getf item :type))
            (uuid (getf item :id)))
        (let* ((resource (find-resource-by-name item-type))
               (relation (find-resource-link-by-json-key resource relation-string))
               (target-type (resource-name relation)))
          (dolist (new-uuid
                    (jsown:filter
                     (sparql:select (s-var "target")
                                    (format nil (s+ "?s mu:uuid ~A."
                                                    "?s ~{~A/~}mu:uuid ?target")
                                            (s-str uuid)
                                            (ld-property-list relation)))
                     map "target" "value"))
            (included-items-store-ensure new-items
                                         `(:type ,target-type :id ,new-uuid))))))
    new-items))
