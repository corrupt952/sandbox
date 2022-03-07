import { useState } from 'react'
import './App.css'
import { DataGrid } from '@mui/x-data-grid'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import Welcome from './components/pages/Welcome'

function App() {
  const [count, setCount] = useState(0)

  return (
    <>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Welcome />} />
        </Routes>
      </BrowserRouter>
    </>
  )
}

export default App
