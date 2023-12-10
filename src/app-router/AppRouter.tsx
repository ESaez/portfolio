import React from "react";
import { lazy, Suspense } from "react";
import { BrowserRouter, Route, Routes } from "react-router-dom";

const Main = lazy(() => import("../views/Main"));

// Define the component with a named function
function AppRouter() {
  return (
    <BrowserRouter>
      <Suspense fallback={<div>Loading routes</div>}>
        <Routes>
          <Route path="/" element={<Main />} />
        </Routes>
      </Suspense>
    </BrowserRouter>
  );
}

export default AppRouter;
