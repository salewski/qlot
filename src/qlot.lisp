(in-package :cl-user)
(defpackage qlot
  (:use :cl)
  (:import-from :qlot.util
                :with-package-functions
                :with-local-quicklisp
                :pathname-in-directory-p
                :all-required-systems)
  (:export :install
           :update
           :install-quicklisp
           :quickload
           :bundle
           :with-local-quicklisp))
(in-package :qlot)

(defun ensure-qlot-install ()
  (unless (find-package :qlot.install)
    (format t "~&Initializing... This may take awhile...~%")
    #+quicklisp (ql:quickload :qlot-install :silent t)
    #-quicklisp (asdf:load-system :qlot-install)))

(defun install (&rest args)
  "Install Quicklisp and libraries that declared in qlfile project-locally.
qlfile.lock will be used with precedence if it exists."
  (ensure-qlot-install)
  (with-package-functions :qlot.install (install-project)
    (if (evenp (length args))
        (apply #'install-project *default-pathname-defaults* args)
        (apply #'install-project args))))

(defun update (&rest args)
  "Update the project-local 'quicklisp/' directory using qlfile."
  (ensure-qlot-install)
  (with-package-functions :qlot.install (update-project)
    (if (evenp (length args))
        (apply #'update-project *default-pathname-defaults* args)
        (apply #'update-project args))))

(defun install-quicklisp (&optional (path nil path-specified-p))
  "Install Quicklisp in the given PATH.
If PATH isn't specified, this installs it to './quicklisp/'."
  (ensure-qlot-install)
  (with-package-functions :qlot.install (install-quicklisp)
    (apply #'install-quicklisp (if path-specified-p
                                   (list path)
                                   nil))))

(defun quickload (systems &rest args &key verbose prompt explain &allow-other-keys)
  "Load SYSTEMS in the each project-local `quicklisp/`."
  (declare (ignore verbose prompt explain))
  (unless (consp systems)
    (setf systems (list systems)))
  (with-package-functions :ql (quickload)
    (loop for system-name in systems
          do (with-local-quicklisp system-name
               (apply #'quickload system-name args))))
  systems)

(defun bundle (&optional (project-dir *default-pathname-defaults*))
  (typecase project-dir
    ((or symbol string)
     (setf project-dir
           (asdf:system-source-directory (asdf:find-system project-dir)))))
  (let ((qlhome (merge-pathnames #P"quicklisp/" project-dir))
        systems required-systems)
    (unless (probe-file qlhome)
      (error "~S is not ready to qlot:bundle. Try qlot:install first." project-dir))
    (asdf::collect-sub*directories-asd-files
     project-dir
     :collect (lambda (asd)
                (unless (or (pathname-in-directory-p asd qlhome)
                            ;; KLUDGE: Ignore skeleton.asd of CL-Project
                            (search "skeleton" (pathname-name asd)))
                  (push asd systems)))
     :exclude (cons "bundle-libs" asdf::*default-source-registry-exclusions*))
    (when systems
      (load (first systems))
      (with-local-quicklisp (pathname-name (first systems))
        (with-package-functions :ql-dist (find-system)
          (labels ((system-dependencies (system-name)
                   (let ((system (asdf:find-system system-name nil)))
                     (cond
                       ((or (null system)
                            (not (equal (asdf:component-pathname system)
                                        (uiop:pathname-directory-pathname (first systems)))))
                        (cons
                         system-name
                         (all-required-systems system-name)))
                       (t
                        ;; Probably the user application's system.
                        ;; Continuing looking for it's dependencies
                        (mapcan #'system-dependencies
                                (mapcar #'string-downcase
                                        (asdf::component-sideway-dependencies system))))))))
            (setf required-systems
                  (delete-if (lambda (system)
                               (or (member system systems :key #'pathname-name :test #'string-equal)
                                   (not (find-system system))))
                             (delete-duplicates
                              (mapcan #'system-dependencies
                               (mapcar #'pathname-name systems))
                              :test #'string=)))))))
    (if required-systems
        (progn
          (format t "~&Bundle ~D ~:*system~[s~;~:;s~]:~%" (length required-systems))
          (princ "  ")
          (loop for i from 1
                for (system . rest) on required-systems
                do (princ system)
                if (zerop (mod i 5))
                  do (format t "~&  ")
                else if rest
                       do (write-char #\Space))
          (fresh-line)
          (with-local-quicklisp (pathname-name (first systems))
            (with-package-functions :ql-dist (enabled-dists
                                              canonical-distinfo-url
                                              (setf canonical-distinfo-url))
              (let ((dists (enabled-dists)))
                ;; KLUDGE: Quicklisp client 2017-03-06 requires CANONICAL-DISTINFO-URL for all enabled dists.
                ;;   However, dists installed via Qlot doesn't have it and raises SLOT-UNBOUND error.
                ;;   For the meanwhile, setting it NIL and using the dists in BUNDLE-SYSTEMS.
                (dolist (dist dists)
                  (unless (ignore-errors (canonical-distinfo-url dist))
                    (setf (canonical-distinfo-url dist) nil)))
                (progv (list (intern (string :*dist-enumeration-functions*) :ql-dist))
                    (list `(,(lambda () dists)))
                  (with-package-functions :ql (bundle-systems)
                    (bundle-systems required-systems
                                    :to (merge-pathnames #P"bundle-libs/" project-dir)))))))
          (with-open-file (out (merge-pathnames #P"bundle-libs/local-projects/ignore" project-dir)
                               :direction :output
                               :if-exists nil))
          (format t "~&Successfully bundled to '~A'.~%Load 'bundle-libs/bundle.lisp' to use it.~%"
                  (merge-pathnames #P"bundle-libs/" project-dir)))
        (format t "~&Nothing to bundle.~%"))))
